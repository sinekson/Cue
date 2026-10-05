import SwiftUI

// MARK: - Home & Content

/// Settings → Home & Content: Home's rows (their order, names, which show),
/// Continue Watching's order, TMDB's language, and the add-ons.
struct HomeContentSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @EnvironmentObject private var tmdb: TMDBSettingsStore

    var body: some View {
        let rows = HomeRowEntry.all(addonManager: addonManager, collections: collections, settings: settings)
        let hidden = rows.filter { !$0.isShown(settings: settings) }.count
        SettingsPage(place: SettingsCategory.homeContent.place, subtitle: SettingsCategory.homeContent.subtitle) {
            SettingsSection(title: "Home") {
                SettingsLinkRow(
                    title: "Rows",
                    description: "Home's rows: their order, their names, and which ones show.",
                    value: hidden > 0 ? "\(rows.count) · \(hidden) hidden" : "\(rows.count)"
                ) { HomeRowsPage() }

                // Two options: Select switches between them in place.
                SettingsButtonRow(
                    title: "Continue Watching order",
                    description: "Recently watched: the title you played last comes first.\n\n"
                        + "Streaming style: titles you're in the middle of come first, newest first; "
                        + "ones you've barely started follow.",
                    value: settings.continueWatchingSortMode.displayName
                ) {
                    settings.continueWatchingSortMode =
                        settings.continueWatchingSortMode == .recentlyWatched ? .streamingStyle : .recentlyWatched
                }
            }

            SettingsSection(title: "Content") {
                SettingsChoiceRow(
                    title: "Language",
                    description: "The language of titles, summaries and artwork from TMDB.",
                    options: TMDBLanguages.options.map { SettingsOption(id: $0, label: TMDBLanguages.displayName($0)) },
                    selection: tmdb.settings.language
                ) { tmdb.settings.language = $0 }
            }

            SettingsSection(title: "Add-ons") {
                SettingsLinkRow(
                    title: "Add-ons",
                    description: "Where Home's rows, the sources and subtitles come from: add one, and their order, names and settings.",
                    value: "\(addonManager.addons.count)"
                ) { AddonsPage() }

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

/// Settings → Home & Content → Rows: Home's rows in order, each one line —
/// Rename (the keyboard at once), Move, and a switch for showing it.
private struct HomeRowsPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @State private var moving: String?
    @State private var keyboard: KeyboardRequest?

    var body: some View {
        let rows = HomeRowEntry.all(addonManager: addonManager, collections: collections, settings: settings)
        SettingsManagePage(title: "Home rows", subtitle: "Rename, move or hide Home's rows.") {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let shown = row.isShown(settings: settings)
                SettingsEntryRow(
                    title: row.title(settings: settings),
                    scrollID: row.id,
                    dimmed: !shown,
                    actions: actions(for: row),
                    toggle: SettingsEntrySwitch(isOn: shown, title: shown ? "Hide" : "Show") {
                        settings.setEnabled(!shown, key: row.key)
                    },
                    isMoving: moving == row.id,
                    anyMoving: moving != nil,
                    onMoveStep: { step in
                        guard rows.indices.contains(index + step) else { return }
                        settings.move(key: row.key, up: step < 0,
                                      within: HomeRowEntry.catalogKeys(addonManager)
                                          + HomeRowEntry.collectionKeys(collections))
                    },
                    onDrop: { moving = nil }
                )
            }
        }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        .onChange(of: moving) { _, id in TopBarLock.shared.locked = id != nil }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    private func actions(for row: HomeRowEntry) -> [SettingsEntryAction] {
        var actions: [SettingsEntryAction] = []
        actions.append(SettingsEntryAction(id: "rename", icon: "pencil", title: "Rename") {
            keyboard = KeyboardRequest(text: row.title(settings: settings), placeholder: row.defaultTitle) { text in
                // Empty or the original: its own name again.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.setCustomTitle(trimmed == row.defaultTitle ? nil : trimmed, key: row.key)
            }
        })
        actions.append(SettingsEntryAction(id: "move", icon: "arrow.up.arrow.down", title: "Move") {
            moving = row.id
        })
        return actions
    }
}

// MARK: - Add-ons

/// Settings → Home & Content → Add-ons: a round + by the heading (adding,
/// from your phone), then the add-ons in order, each one line — Configure
/// (when it has settings), Rename, Move, a switch for on / off, Remove.
private struct AddonsPage: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @State private var moving: String?
    @State private var keyboard: KeyboardRequest?
    @State private var adding = false
    @State private var configuring: InstalledAddon?
    @State private var removing: InstalledAddon?

    var body: some View {
        let configurable = addonManager.addons.contains { $0.configureURL != nil }
        SettingsManagePage(
            title: "Add-ons",
            subtitle: "Higher ones come first for sources. Add one with + (from your phone).",
            headerAction: SettingsEntryAction(id: "add", icon: "plus", title: "Add an add-on") { adding = true }
        ) {
            ForEach(Array(addonManager.addons.enumerated()), id: \.element.id) { index, addon in
                SettingsEntryRow(
                    title: addon.displayName,
                    scrollID: addon.id,
                    dimmed: !addon.enabled,
                    leading: AnyView(AddonLogo(addon: addon)),
                    extra: addon.configureURL == nil ? nil
                        : SettingsEntryAction(id: "configure", icon: "slider.horizontal.3", title: "Configure") {
                            configuring = addon
                        },
                    reservesExtra: configurable,
                    actions: [
                        SettingsEntryAction(id: "rename", icon: "pencil", title: "Rename") {
                            keyboard = KeyboardRequest(text: addon.displayName, placeholder: addon.manifest.name) {
                                addonManager.rename(addon, to: $0)
                            }
                        },
                        SettingsEntryAction(id: "move", icon: "arrow.up.arrow.down", title: "Move") {
                            moving = addon.id
                        },
                    ],
                    toggle: SettingsEntrySwitch(isOn: addon.enabled, title: addon.enabled ? "Turn off" : "Turn on") {
                        addonManager.setEnabled(addon, !addon.enabled)
                    },
                    remove: SettingsEntryAction(id: "remove", icon: "trash", title: "Remove") { removing = addon },
                    isMoving: moving == addon.id,
                    anyMoving: moving != nil,
                    onMoveStep: { step in addonManager.move(addon, to: index + step) },
                    onDrop: { moving = nil }
                )
            }
        }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        .onChange(of: moving) { _, id in TopBarLock.shared.locked = id != nil }
        .onDisappear { TopBarLock.shared.locked = false }
        .fullScreenCover(isPresented: $adding) {
            AddonPhoneAddView(addonManager: addonManager) { adding = false }
                .environmentObject(theme)
        }
        .fullScreenCover(item: $configuring) { addon in
            AddonPhoneAddView(addonManager: addonManager, configuring: addon) { configuring = nil }
                .environmentObject(theme)
        }
        .alert("Remove \(removing?.displayName ?? "")?",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { addon in
            Button("Remove", role: .destructive) {
                addonManager.remove(addon)
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { _ in
            Text("It's removed from this device and your account. You can add it back later with its link.")
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

// MARK: - Collections (the editor; its entries are hidden for now)

/// On/off checkmark beside a collection or folder row.
///
/// `PlainCardButtonStyle` supplies only a press dip — the focus VISUAL is the
/// label's own job, which is why `RowControlIcon` below draws one. These
/// checkmarks were a bare `Image`, so moving focus left off the row and onto
/// the checkmark made the highlight vanish: the row un-highlighted and nothing
/// took its place, so there was no way to tell what was selected.
private struct CheckToggleIcon: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let isOn: Bool

    var body: some View {
        // The flat control; ticked: white, else muted.
        FlatIconCircle(icon: isOn ? "checkmark.circle.fill" : "circle", iconSize: 26,
                       restTint: isOn ? FlatControl.content : FlatControl.contentMuted)
    }
}

/// Small circular icon control (move/rename/hide): the flat control.
private struct RowControlIcon: View {
    let icon: String

    var body: some View { FlatIconCircle(icon: icon) }
}

/// Settings → Collections: create and edit collections (custom home rows of
/// folders, each backed by TMDB / Trakt sources). Synced whole as a JSON
/// blob via `sync_push_collections`.
struct CollectionsSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore

    private var providers: CollectionProviders {
        CollectionProviders(tmdb: tmdbSettings.isEnabled, trakt: TraktService.isConfigured)
    }

    @State private var editing: CueCollection?
    @State private var creating = false

    var body: some View {
        DetailScaffold(title: "Collections", subtitle: "Group TMDB and Trakt sources into custom home rows") {
            if !providers.any {
                // Collections resolve from TMDB and Trakt and nothing else.
                // They still show on Home with neither connected — every
                // folder just opens empty with this same pointer — so say it
                // here too, where the fix is one screen away. Either service
                // is enough; when both are connected TMDB is the one used.
                HStack(alignment: .top, spacing: CueSpacing.md) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(theme.palette.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect TMDB or Trakt")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text("Collections need one of them to load anything — just one is enough. "
                             + "Add your free TMDB API key in Settings → Integrations → TMDB for the "
                             + "full range of sources, or sign in to Trakt in Settings → Trakt for your lists.")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
                .padding(CueSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                        .fill(theme.palette.backgroundCard.opacity(0.5))
                )
            }

            CollectionLayoutModePicker()

            Button { creating = true } label: {
                SettingsActionRow(
                    title: "New Collection",
                    subtitle: "A custom home row of catalog folders",
                    leadingIcon: "plus.circle.fill"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            // The LIBRARY, not the visible subset — a collection switched off
            // account-wide has to stay listed here or there'd be no way to turn
            // it back on.
            ForEach(collections.library) { collection in
                let on = collections.isGloballyVisible(collection.id)
                HStack(spacing: CueSpacing.md) {
                    Button {
                        collections.setGloballyVisible(!on, id: collection.id)
                    } label: {
                        CheckToggleIcon(isOn: on)
                    }
                    .buttonStyle(PlainCardButtonStyle())

                    Button { editing = collection } label: {
                        SettingsActionRow(
                            title: collection.title,
                            subtitle: on
                                ? "\(collection.folders.count) folder\(collection.folders.count == 1 ? "" : "s")"
                                : "Off for all profiles · \(collection.folders.count) folder\(collection.folders.count == 1 ? "" : "s")",
                            leadingIcon: "rectangle.stack.fill"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .opacity(on ? 1 : 0.45)
                }
            }

            if collections.library.isEmpty {
                Text("No collections yet. A collection appears as its own home row of folder tiles — like \"Marvel\" with folders for each phase.")
                    .font(.system(size: 21))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .fullScreenCover(isPresented: $creating) {
            CollectionEditorView(collection: nil) { creating = false }
                .environmentObject(theme)
                .environmentObject(collections)
        }
        .fullScreenCover(item: $editing) { collection in
            CollectionEditorView(collection: collection) { editing = nil }
                .environmentObject(theme)
                .environmentObject(collections)
        }
    }
}

/// Settings → Collections: one account-wide layout for EVERY collection, or
/// Custom to keep each collection's own. Sits above the list because it decides
/// whether the per-collection Layout control inside each editor applies at all.
private struct CollectionLayoutModePicker: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.md) {
            Text("Layout for all collections")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            HStack(spacing: CueSpacing.md) {
                ForEach(CollectionLayoutMode.allCases) { mode in
                    Button {
                        collections.globalLayoutMode = mode
                    } label: {
                        FolderTabPill(label: mode.displayName,
                                      selected: collections.globalLayoutMode == mode)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                }
            }
            Text(collections.globalLayoutMode.summary)
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

// MARK: - Collection editor

/// Create/edit one collection: title, folders, and each folder's TMDB / Trakt
/// sources (both need their integration configured — TMDB wants the viewer's
/// own API key. Add-on sources written by other devices are preserved
/// untouched, but they no longer resolve here).
struct CollectionEditorView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var addonManager: AddonManager

    let collection: CueCollection?
    let onDone: () -> Void

    @State private var title = ""
    @State private var folders: [CueCollectionFolder] = []
    @State private var editingFolder: CueCollectionFolder?
    @State private var addingFolder = false
    @State private var pinToTop = false
    @State private var focusGlowEnabled = true
    @State private var showAllTab = true
    @State private var viewMode = "ROWS"
    /// Stable id used for every autosave write (a new collection keeps the same
    /// id across edits instead of creating duplicates).
    @State private var collectionID = ""
    /// Gates autosave until the initial values are loaded, so seeding the
    /// fields in onAppear doesn't immediately write back.
    @State private var didLoad = false
    /// Title edits arrive per keystroke; each store write re-fingerprints Home
    /// and triggers a full catalog reload, so the title autosave is debounced.
    @State private var titlePersistTask: Task<Void, Never>?

    private var isNew: Bool { collection == nil }

    var body: some View {
        ZStack {
            ATVBackground()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: CueSpacing.xl) {
                    Text(isNew ? "New Collection" : "Edit Collection")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    TextField("Collection name", text: $title)
                        .font(.system(size: 26))
                        .frame(maxWidth: 700)

                    SettingsToggleCard(
                        title: "Pin to top of Home",
                        subtitle: "Show this collection's row before the catalogs",
                        isOn: $pinToTop
                    )
                    SettingsToggleCard(
                        title: "Focus glow",
                        subtitle: "Highlight tiles with a soft glow when focused",
                        isOn: $focusGlowEnabled
                    )
                    SettingsToggleCard(
                        title: "\"All\" tab",
                        subtitle: "Show a combined tab alongside each folder's tab in the browser",
                        isOn: $showAllTab
                    )
                    // The per-collection layout only means anything while the
                    // account-wide mode is Custom — otherwise every collection
                    // is forced to one layout and this control would lie.
                    if collections.globalLayoutMode == .custom {
                        CollectionLayoutPicker(viewMode: $viewMode)
                    } else {
                        VStack(alignment: .leading, spacing: CueSpacing.sm) {
                            Text("Layout")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(theme.palette.textPrimary)
                            Text("All collections are set to \(collections.globalLayoutMode.displayName) in Settings → Collections. Switch that to Custom to give this one its own layout.")
                                .font(.system(size: 20))
                                .foregroundStyle(theme.palette.textSecondary)
                                .frame(maxWidth: 900, alignment: .leading)
                        }
                    }

                    Text("Folders")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    Button { addingFolder = true } label: {
                        SettingsActionRow(
                            title: "Add Folder",
                            subtitle: "Pick TMDB or Trakt sources to fill it",
                            leadingIcon: "folder.badge.plus"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())

                    ForEach(folders) { folder in
                        HStack(spacing: CueSpacing.md) {
                            // Account-wide on/off for this folder. Every profile
                            // inherits it; a profile can hide MORE in Profile
                            // Manager but can't re-enable what's off here — so
                            // this is the shared baseline everyone starts from.
                            Button {
                                collections.setFolderGloballyVisible(
                                    !collections.isFolderGloballyVisible(folder.id), id: folder.id)
                            } label: {
                                CheckToggleIcon(isOn: collections.isFolderGloballyVisible(folder.id))
                            }
                            .buttonStyle(PlainCardButtonStyle())

                            Button { editingFolder = folder } label: {
                                SettingsActionRow(
                                    title: folder.title.isEmpty ? "Untitled folder" : folder.title,
                                    subtitle: collections.isFolderGloballyVisible(folder.id)
                                        ? folderSubtitle(folder)
                                        : "Off for all profiles — " + folderSubtitle(folder),
                                    leadingIcon: "folder.fill"
                                )
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .opacity(collections.isFolderGloballyVisible(folder.id) ? 1 : 0.45)

                            Button(role: .destructive) {
                                folders.removeAll { $0.id == folder.id }
                                persist()
                            } label: {
                                RowControlIcon(icon: "trash")
                            }
                        }
                    }

                    // Changes autosave — no Save button. "Done" flushes any
                    // debounced title edit, then dismisses.
                    HStack(spacing: CueSpacing.lg) {
                        Button("Done") {
                            titlePersistTask?.cancel()
                            persist(finalizing: true)
                            onDone()
                        }
                        // Against the LIBRARY, not the visible subset: a
                        // collection switched off for all profiles is exactly
                        // the one with no other way to be deleted.
                        if collections.library.contains(where: { $0.id == collectionID }) {
                            Button("Delete Collection", role: .destructive) {
                                // Cancel the debounced title autosave FIRST: it
                                // would otherwise fire after the delete, find no
                                // existing collection, and re-add the one just
                                // removed.
                                titlePersistTask?.cancel()
                                collections.remove(id: collectionID)
                                onDone()
                            }
                        }
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, CueSpacing.lg)
                }
                .padding(CueSpacing.huge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .onAppear {
            if let collection {
                collectionID = collection.id
                title = collection.title
                folders = collection.folders
                pinToTop = collection.pinToTop
                focusGlowEnabled = collection.focusGlowEnabled ?? true
                showAllTab = collection.showAllTab
                viewMode = collection.viewMode
            } else if collectionID.isEmpty {
                collectionID = collections.generateID()
            }
            didLoad = true
        }
        // Every field autosaves; scalar changes persist here, folder changes
        // persist at their mutation sites. Title is debounced (see
        // titlePersistTask); Done/dismiss flushes it via the pending task.
        .onChange(of: title) { _, _ in
            titlePersistTask?.cancel()
            titlePersistTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                persist()
            }
        }
        .onChange(of: pinToTop) { _, _ in persist() }
        .onChange(of: focusGlowEnabled) { _, _ in persist() }
        .onChange(of: showAllTab) { _, _ in persist() }
        .onChange(of: viewMode) { _, _ in persist() }
        // Changes are already saved — flush any debounced title edit and dismiss.
        .onExitCommand {
            titlePersistTask?.cancel()
            persist(finalizing: true)
            onDone()
        }
        .fullScreenCover(isPresented: $addingFolder) {
            FolderEditorView(folder: nil) { newFolder in
                if let newFolder { folders.append(newFolder); persist() }
                addingFolder = false
            }
            .environmentObject(theme)
            .environmentObject(addonManager)
        }
        .fullScreenCover(item: $editingFolder) { folder in
            FolderEditorView(folder: folder) { updated in
                if let updated, let index = folders.firstIndex(where: { $0.id == updated.id }) {
                    folders[index] = updated
                    persist()
                }
                editingFolder = nil
            }
            .environmentObject(theme)
            .environmentObject(addonManager)
        }
    }

    /// Upsert the current editor state into the store. A brand-new collection
    /// isn't materialized until it has a name, so opening "New Collection" and
    /// backing straight out doesn't leave an empty row behind.
    /// `finalizing` marks the LAST write of an editing session (Done / Back).
    /// Only then may an unnamed collection take its name from its first
    /// folder: doing it on the autosave path would stamp a name onto the
    /// collection the instant a folder was added, mid-typing.
    private func persist(finalizing: Bool = false) {
        guard didLoad else { return }
        // Never autosave an empty name — mid-retype the field passes through
        // "" and the old Save button refused it too. The last good title holds
        // until a non-empty one is typed.
        var trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, finalizing {
            // Built the folders, never typed a name, pressed Done: name it
            // after what's in it rather than throwing the work away silently.
            trimmed = folders.first { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }?
                .title.trimmingCharacters(in: .whitespaces) ?? ""
        }
        guard !trimmed.isEmpty else { return }
        // The LIBRARY copy. Looking the id up in the visible list missed any
        // collection switched off in Settings, so every Back out of its editor
        // treated it as new and appended a duplicate.
        let existing = collections.library.first(where: { $0.id == collectionID })
        var c = existing ?? CueCollection(id: collectionID, title: trimmed)
        c.title = trimmed
        c.folders = folders
        c.pinToTop = pinToTop
        c.focusGlowEnabled = focusGlowEnabled
        c.showAllTab = showAllTab
        c.viewMode = viewMode
        // No-op writes (e.g. the onAppear seed round-trip) would still fire the
        // store's change hooks — a spurious account push + full Home reload on
        // every editor open.
        if let existing {
            guard c != existing else { return }
            collections.update(c)
        } else {
            collections.add(c)
        }
    }

    private func folderSubtitle(_ folder: CueCollectionFolder) -> String {
        let liveCount = folder.effectiveSources.count - folder.addonSources.count
        guard liveCount > 0 else {
            guard !folder.addonSources.isEmpty else { return "No sources" }
            // An add-on-only folder — which is every folder of an imported
            // pack — fills itself from its add-on's catalogs, so say which,
            // by the SAME rule the browse screen resolves by. "No TMDB/Trakt
            // sources" was true to the letter and wrong in effect: it read as
            // "this can't load" under folders that load fine, which is the
            // report that had them adding TMDB sources to fix nothing.
            let live = folder.addonSources.filter {
                CollectionResolver.addonCatalog(for: $0, addons: addonManager.addons) != nil
            }.count
            guard live > 0 else { return "Add-on not installed on this profile" }
            return "\(live) add-on catalog\(live == 1 ? "" : "s")"
        }
        return "\(liveCount) TMDB/Trakt source\(liveCount == 1 ? "" : "s")"
    }

}

// MARK: - Folder editor

/// Edit one folder: name and which TMDB / Trakt sources feed it.
///
/// Categories are a TMDB/Trakt feature — there is no add-on catalog picker here
/// any more. Add-on sources on a folder authored elsewhere are kept in storage
/// (so this editor never rewrites the phone's copy) but they no longer resolve.
private struct FolderEditorView: View {
    @EnvironmentObject private var theme: ThemeManager

    let folder: CueCollectionFolder?
    let onDone: (CueCollectionFolder?) -> Void

    @State private var title = ""
    /// Add-on sources this folder already had, preserved verbatim across a save.
    @State private var legacyAddonSources: [CollectionSourceDTO] = []
    /// The TMDB / Trakt sources this editor actually manages.
    @State private var passthroughSources: [CollectionSourceDTO] = []
    @State private var tileShape = "SQUARE"
    @State private var coverURL = ""
    @State private var showSourcePicker = false
    /// Shown next to Save when there is genuinely nothing to save.
    @State private var saveError: String?

    private static let shapes: [(id: String, label: String)] =
        [("SQUARE", "Square"), ("POSTER", "Poster"), ("LANDSCAPE", "Landscape")]

    var body: some View {
        ZStack {
            ATVBackground()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: CueSpacing.xl) {
                    Text(folder == nil ? "New Folder" : "Edit Folder")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    TextField("Folder name", text: $title)
                        .font(.system(size: 26))
                        .frame(maxWidth: 700)

                    Text("TMDB / Trakt Sources")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    Button { showSourcePicker = true } label: {
                        SettingsActionRow(
                            title: "Add TMDB / Trakt Source",
                            subtitle: "Studios, networks, people, discover feeds, or a Trakt list",
                            leadingIcon: "plus.circle.fill"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())

                    // ONE focusable control per row, and the row itself is it.
                    // The label used to be a plain `SettingsActionRow` with a
                    // separate trash button beside it, so the only thing that
                    // could be selected on a source was Delete — "cannot select
                    // Netflix, only delete". Selecting the row is now what
                    // removes it, and the row says so.
                    ForEach(Array(passthroughSources.enumerated()), id: \.offset) { index, source in
                        Button {
                            guard passthroughSources.indices.contains(index) else { return }
                            passthroughSources.remove(at: index)
                        } label: {
                            HStack(spacing: CueSpacing.md) {
                                SettingsActionRow(
                                    title: source.title?.isEmpty == false ? source.title! : (source.tmdbSourceType ?? "Trakt List"),
                                    subtitle: (source.isTraktSource ? "Trakt list" : "TMDB \((source.tmdbSourceType ?? "").capitalized)")
                                        + " — select to remove",
                                    leadingIcon: source.isTraktSource ? "checkmark.seal.fill" : "film.fill"
                                )
                                Image(systemName: "trash")
                                    .font(.system(size: 22))
                                    .foregroundStyle(CuePrimitives.error)
                            }
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }

                    // Tile shape — Square / Poster / Landscape.
                    Text("Tile Shape")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                    HStack(spacing: CueSpacing.md) {
                        ForEach(Self.shapes, id: \.id) { shape in
                            Button { tileShape = shape.id } label: {
                                ShapeChip(label: shape.label, selected: tileShape == shape.id)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }

                    // Cover image — a high-quality picture used on the tile and
                    // as the collection's background.
                    Text("Cover Image URL")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                    TextField("https://…/image.jpg", text: $coverURL)
                        .font(.system(size: 24))
                        .padding(.horizontal, CueSpacing.lg)
                        .padding(.vertical, CueSpacing.md)
                        .background(theme.palette.field, in: RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous))
                        .frame(maxWidth: 900)

                    HStack(spacing: CueSpacing.lg) {
                        // NEVER `.disabled` here. A disabled tvOS button is not
                        // focusable, and a ScrollView only scrolls when focus
                        // moves — so with the name field left blank (which is
                        // the normal state right after adding a source from the
                        // picker) Save was both unreachable AND unscrollable-to,
                        // which is the "can't scroll down to save" report. The
                        // name is derived from the first source instead, and
                        // `save()` explains itself if there is nothing to name.
                        Button("Save", action: save)
                        Button("Cancel", role: .cancel) { onDone(nil) }
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, CueSpacing.lg)

                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 20))
                            .foregroundStyle(CuePrimitives.error)
                    }
                }
                .padding(CueSpacing.huge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .onAppear {
            guard let folder else { return }
            title = folder.title
            tileShape = folder.tileShape
            coverURL = folder.coverImageUrl ?? ""
            passthroughSources = folder.effectiveSources.filter { !$0.isAddonSource }
            legacyAddonSources = folder.addonSources
        }
        // Same as Cancel — dismiss without saving.
        .onExitCommand { onDone(nil) }
        .fullScreenCover(isPresented: $showSourcePicker) {
            CollectionSourcePickerView(
                onAdd: { passthroughSources.append($0) },
                onDone: { showSourcePicker = false }
            )
            .environmentObject(theme)
        }
    }

    private func save() {
        // An unnamed folder takes the name of what's in it — "Netflix", not a
        // refusal. Typing a name is still what most people do; this just stops
        // the form from being a dead end when they don't.
        var trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            trimmed = passthroughSources.compactMap { source in
                let candidate = source.title?.trimmingCharacters(in: .whitespaces) ?? ""
                return candidate.isEmpty ? nil : candidate
            }.first ?? ""
        }
        guard !trimmed.isEmpty else {
            saveError = "Give the folder a name, or add a source to name it after."
            return
        }
        saveError = nil
        var result = folder ?? CueCollectionFolder(id: UUID().uuidString, title: trimmed, sources: [])
        result.title = trimmed
        // Addon rows ride along untouched: they resolve to nothing here, but
        // dropping them would sync that deletion to every other client.
        result.sources = legacyAddonSources + passthroughSources
        result.catalogSources = legacyAddonSources
        result.tileShape = tileShape
        let trimmedCover = coverURL.trimmingCharacters(in: .whitespaces)
        result.coverImageUrl = trimmedCover.isEmpty ? nil : trimmedCover
        onDone(result)
    }
}

/// Small selectable chip for the tile-shape picker: the flat pill.
private struct ShapeChip: View {
    let label: String
    let selected: Bool

    var body: some View { FlatChip(label: label, selected: selected) }
}
