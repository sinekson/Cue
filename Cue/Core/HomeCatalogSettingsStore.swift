import Foundation

/// The portrait poster grids (collections, See All, studio pages): one
/// size and corner radius, until those screens get the new design.
enum GridPoster {
    /// Width in points; the height is width × 3/2.
    static let width: CGFloat = 220
    static let cornerRadius: CGFloat = 12
}

/// How the Continue Watching row is ordered (mirrors Android's
/// ContinueWatchingSortMode).
enum ContinueWatchingSortMode: String, CaseIterable, Identifiable, Codable {
    case recentlyWatched, streamingStyle
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .recentlyWatched: return "Recently watched"
        case .streamingStyle: return "Streaming style"
        }
    }
    var summary: String {
        switch self {
        case .recentlyWatched: return "Most recently played first"
        case .streamingStyle: return "Titles you're mid-episode on first, then the rest"
        }
    }
}

/// The device-local Home/Continue-Watching presentation prefs that ride in the
/// tvOS-only sync blob (see NuvioSyncManager.AppPreferencesSnapshot).
struct HomePresentationSnapshot: Codable, Equatable {
    var continueWatchingSortMode: ContinueWatchingSortMode = .recentlyWatched
    var autoHideSidebar = false
    var fullStreamTitles = false
    var heroTrailersEnabled = true
    var heroTrailerSound = false
}

/// Tolerant decoding (in an extension so the memberwise init survives): a blob
/// written before a field existed decodes with that field's default instead of
/// failing wholesale and resetting every presentation pref on app update.
extension HomePresentationSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HomePresentationSnapshot()
        continueWatchingSortMode = (try? c.decode(ContinueWatchingSortMode.self, forKey: .continueWatchingSortMode)) ?? d.continueWatchingSortMode
        autoHideSidebar = (try? c.decode(Bool.self, forKey: .autoHideSidebar)) ?? d.autoHideSidebar
        fullStreamTitles = (try? c.decode(Bool.self, forKey: .fullStreamTitles)) ?? d.fullStreamTitles
        heroTrailersEnabled = (try? c.decode(Bool.self, forKey: .heroTrailersEnabled)) ?? d.heroTrailersEnabled
        heroTrailerSound = (try? c.decode(Bool.self, forKey: .heroTrailerSound)) ?? d.heroTrailerSound
    }
}

// MARK: - Sync payload (matches Android's home-catalog settings_json exactly)

/// The cross-platform home-catalog layout, wire-identical to the Cue Android
/// app: a flat ordered list of keys plus a disabled set and a custom-title map.
/// Keys are `{addonId}_{type}_{catalogId}` for addon catalogs and
/// `collection_{id}` for collections — so where a catalog sits, where a
/// collection sits, whether it's shown, and its custom title all round-trip
/// between the phone and the Apple TV. (The earlier `items:[{…}]` shape was
/// tvOS-only and silently didn't interoperate with the phone.)
struct SyncHomeCatalogPayload: Codable, Hashable {
    var orderKeys: [String] = []
    var disabledKeys: [String] = []
    var customTitles: [String: String] = [:]
    var hideUnreleasedContent: Bool = false

    private enum CodingKeys: String, CodingKey {
        case orderKeys = "home_catalog_order_keys"
        case disabledKeys = "disabled_home_catalog_keys"
        case customTitles = "custom_catalog_titles"
        case hideUnreleasedContent = "hide_unreleased_content"
    }

    init(orderKeys: [String] = [], disabledKeys: [String] = [],
         customTitles: [String: String] = [:], hideUnreleasedContent: Bool = false) {
        self.orderKeys = orderKeys
        self.disabledKeys = disabledKeys
        self.customTitles = customTitles
        self.hideUnreleasedContent = hideUnreleasedContent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderKeys = try c.decodeIfPresent([String].self, forKey: .orderKeys) ?? []
        disabledKeys = try c.decodeIfPresent([String].self, forKey: .disabledKeys) ?? []
        customTitles = try c.decodeIfPresent([String: String].self, forKey: .customTitles) ?? [:]
        hideUnreleasedContent = try c.decodeIfPresent(Bool.self, forKey: .hideUnreleasedContent) ?? false
    }

    var isEmpty: Bool { orderKeys.isEmpty && disabledKeys.isEmpty && customTitles.isEmpty }
}

// MARK: - Store

/// Home layout customization: which catalog rows show, their order, and custom
/// titles — plus collection rows interleaved. Keys match Android's
/// HomeCatalogSyncSupport: `{addonId}_{type}_{catalogId}` for addon catalogs
/// (addonId = manifest id, NOT the manifest URL) and `collection_{id}` for
/// collections, so settings sync cross-platform via
/// `sync_push/pull_home_catalog_settings`.
@MainActor
final class HomeCatalogSettingsStore: ObservableObject {
    @Published private(set) var orderKeys: [String] = []
    @Published private(set) var disabledKeys: Set<String> = []
    @Published private(set) var customTitles: [String: String] = [:]
    /// Nuvio's "hide unreleased content" — part of the home layout Nuvio's
    /// apps share, so it's carried through sync untouched. Cue doesn't read
    /// it (no setting, no filter): not sending it back would reset it on the
    /// account's other devices.
    @Published var hideUnreleasedContent: Bool = false {
        didSet {
            guard hideUnreleasedContent != oldValue else { return }
            save()
            notifyLocalChange()
        }
    }
    /// Keep the glass rail off screen until it's wanted. It reappears on a
    /// sideways press from the leftmost content (and on Menu), so the rows run
    /// the full width of the screen the rest of the time.
    @Published var autoHideSidebar: Bool = false {
        didSet { guard autoHideSidebar != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Sources page: let every link's release name wrap in full instead of
    /// truncating — the whole point of a remux hunt is reading the whole name.
    @Published var fullStreamTitles: Bool = false {
        didSet { guard fullStreamTitles != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Netflix-style billboard preview on the home hero (HeroTrailerLayer).
    @Published var heroTrailersEnabled: Bool = true {
        didSet { guard heroTrailersEnabled != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Play that preview with sound instead of muted.
    @Published var heroTrailerSound: Bool = false {
        didSet { guard heroTrailerSound != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Continue Watching row ordering.
    @Published var continueWatchingSortMode: ContinueWatchingSortMode = .recentlyWatched {
        didSet { guard continueWatchingSortMode != oldValue else { return }; save(); notifyPresentationChange() }
    }


    var onLocalChange: (() -> Void)?
    /// Fired when a device-local presentation pref changes, so the tvOS sync
    /// blob (player/TMDB/theme/home) can push it.
    var onPresentationChange: (() -> Void)?
    private var suppressChange = false
    /// Read from the SAME key `ProfileStore` persists, so the scope is right
    /// from LAUNCH. The sync manager rescopes every store shortly after start,
    /// but defaulting to 1 here meant a device on any other profile decoded
    /// profile 1's blob on the main actor and then decoded the correct one a
    /// moment later — twice the launch cost, and a reload cascade on top.
    /// `RatingsStore` and `TraktStore` already do this.
    private static let activeProfileKey = "cue.profiles.active"
    private var profileID = UserDefaults.standard.object(forKey: activeProfileKey) as? Int ?? 1

    private static let baseKey = "cue.homecatalog.v1"

    nonisolated static func catalogKey(addonID: String, type: String, catalogID: String) -> String {
        "\(addonID)_\(type)_\(catalogID)"
    }

    nonisolated static func collectionKey(_ collectionID: String) -> String {
        "collection_\(collectionID)"
    }

    private var storageKey: String {
        profileID == 1 ? Self.baseKey : "\(Self.baseKey).p\(profileID)"
    }

    init() {
        load()
    }

    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        load()
    }

    // MARK: Queries

    func isEnabled(key: String) -> Bool { !disabledKeys.contains(key) }

    func customTitle(for key: String) -> String? {
        customTitles[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Merge saved order with the currently-available keys, exactly like
    /// Android's buildHomeCatalogSyncPayload: saved keys that still exist keep
    /// their positions; new catalog keys append, then new collection keys.
    func mergedOrder(catalogKeys: [String], collectionKeys: [String]) -> [String] {
        let available = Set(catalogKeys + collectionKeys)
        var seen = Set<String>()
        let savedValid = orderKeys.filter { available.contains($0) && seen.insert($0).inserted }
        let savedSet = Set(savedValid)
        return savedValid
            + catalogKeys.filter { !savedSet.contains($0) }
            + collectionKeys.filter { !savedSet.contains($0) }
    }

    // MARK: Mutations (UI)

    /// Splice saved keys the caller doesn't know about back into a reordered
    /// list. The Layout editor works in `mergedOrder` terms — only what this
    /// device can resolve — so writing its result back verbatim would delete
    /// every key belonging to the phone's add-ons, a disabled add-on, or a
    /// collection this profile hides. Each unknown key re-attaches behind the
    /// same visible key it used to follow (head-anchored ones stay at the
    /// front), so its position survives a reorder it wasn't part of.
    private func reanchoring(_ keys: [String]) -> [String] {
        let known = Set(keys)
        var head: [String] = []
        var trailing: [String: [String]] = [:]
        var anchor: String?
        for key in orderKeys {
            if known.contains(key) {
                anchor = key
            } else if let anchor {
                trailing[anchor, default: []].append(key)
            } else {
                head.append(key)
            }
        }
        var result = head
        for key in keys {
            result.append(key)
            if let extras = trailing[key] { result.append(contentsOf: extras) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    func setOrder(_ keys: [String]) {
        let full = reanchoring(keys)
        guard full != orderKeys else { return }
        orderKeys = full
        save()
        notifyLocalChange()
    }

    func move(key: String, up: Bool, within allKeys: [String]) {
        var keys = mergedOrder(catalogKeys: allKeys.filter { !$0.hasPrefix("collection_") },
                               collectionKeys: allKeys.filter { $0.hasPrefix("collection_") })
        guard let index = keys.firstIndex(of: key) else { return }
        let target = up ? index - 1 : index + 1
        guard keys.indices.contains(target) else { return }
        keys.swapAt(index, target)
        setOrder(keys)
    }

    func setEnabled(_ enabled: Bool, key: String) {
        if enabled { disabledKeys.remove(key) } else { disabledKeys.insert(key) }
        save()
        notifyLocalChange()
    }

    func setCustomTitle(_ title: String?, key: String) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitles.removeValue(forKey: key)
        } else {
            customTitles[key] = trimmed
        }
        save()
        notifyLocalChange()
    }

    // MARK: Sync plumbing

    /// Order to PUSH: every saved key keeps its slot — including keys this
    /// device can't currently resolve — then newly-available catalogs, then
    /// new collections.
    ///
    /// This deliberately does NOT use `mergedOrder`, which filters to what is
    /// available right now. That filter is correct for rendering and wrong for
    /// the wire: the blob is shared across every device, platform and profile,
    /// so "not available HERE" is routinely "installed on the phone",
    /// "belonging to a temporarily disabled add-on", or "hidden on this
    /// profile" — and pushing the filtered list deleted those positions for
    /// everyone. Disabling one add-on, or pushing before add-ons finished
    /// loading, was enough to flatten the account's whole Home order.
    private func exportOrder(catalogKeys: [String], collectionKeys: [String]) -> [String] {
        var seen = Set<String>()
        let saved = orderKeys.filter { seen.insert($0).inserted }
        return saved
            + catalogKeys.filter { seen.insert($0).inserted }
            + collectionKeys.filter { seen.insert($0).inserted }
    }

    /// Build the push payload from currently-available addons + collections.
    /// New catalogs (then collections) append to the saved order, exactly like
    /// Android's buildHomeCatalogSyncPayload; disabled keys and custom titles
    /// ship as-is (they already include anything pulled from the phone, so
    /// cross-device state isn't dropped).
    ///
    /// `collections` must be the account-wide LIBRARY, not a profile's visible
    /// subset — see the note on exportOrder.
    func exportPayload(addons: [InstalledAddon], collections: [CueCollection]) -> SyncHomeCatalogPayload {
        var catalogKeys: [String] = []
        var collectionKeys: [String] = []
        var seen = Set<String>()

        for addon in addons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = Self.catalogKey(addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
                guard seen.insert(key).inserted else { continue }
                catalogKeys.append(key)
            }
        }
        for collection in collections {
            let key = Self.collectionKey(collection.id)
            guard seen.insert(key).inserted else { continue }
            collectionKeys.append(key)
        }

        let order = exportOrder(catalogKeys: catalogKeys, collectionKeys: collectionKeys)
        return SyncHomeCatalogPayload(
            orderKeys: order,
            disabledKeys: Array(disabledKeys),
            customTitles: customTitles,
            hideUnreleasedContent: hideUnreleasedContent
        )
    }

    /// Apply a remote payload (pull). Suppresses the local-change push echo.
    func applyRemote(_ payload: SyncHomeCatalogPayload) {
        suppressChange = true
        orderKeys = payload.orderKeys
        disabledKeys = Set(payload.disabledKeys)
        customTitles = payload.customTitles.filter { !$0.value.isEmpty }
        hideUnreleasedContent = payload.hideUnreleasedContent
        // Lift the suppression BEFORE the write: `save()` now early-returns
        // while suppressed (so a bulk assign writes once, not once per
        // property), and this is the one write that has to land. Matches
        // `applyRemotePresentation` below.
        suppressChange = false
        save()
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var orderKeys: [String]
        var disabledKeys: [String]
        var customTitles: [String: String]
        var hideUnreleasedContent: Bool
        var continueWatchingSortMode: ContinueWatchingSortMode?
        var autoHideSidebar: Bool?
        var fullStreamTitles: Bool?
        var heroTrailersEnabled: Bool?
        var heroTrailerSound: Bool?
    }

    private func notifyLocalChange() {
        guard !suppressChange else { return }
        onLocalChange?()
    }

    private func notifyPresentationChange() {
        guard !suppressChange else { return }
        onPresentationChange?()
    }

    /// The presentation prefs as a syncable snapshot.
    var presentationSnapshot: HomePresentationSnapshot {
        HomePresentationSnapshot(
            continueWatchingSortMode: continueWatchingSortMode,
            autoHideSidebar: autoHideSidebar,
            fullStreamTitles: fullStreamTitles,
            heroTrailersEnabled: heroTrailersEnabled,
            heroTrailerSound: heroTrailerSound,
        )
    }

    /// Every presentation pref back to its shipped default. Called by `load()`
    /// for a profile that has no saved blob, so nothing carries over from the
    /// profile we just switched away from.
    private func applyPresentationDefaults() {
        let d = HomePresentationSnapshot()
        continueWatchingSortMode = d.continueWatchingSortMode
        autoHideSidebar = d.autoHideSidebar
        fullStreamTitles = d.fullStreamTitles
        heroTrailersEnabled = d.heroTrailersEnabled
        heroTrailerSound = d.heroTrailerSound
    }

    /// Apply presentation prefs pulled from the account without echoing back up.
    func applyRemotePresentation(_ s: HomePresentationSnapshot) {
        guard s != presentationSnapshot else { return }
        suppressChange = true
        continueWatchingSortMode = s.continueWatchingSortMode
        autoHideSidebar = s.autoHideSidebar
        fullStreamTitles = s.fullStreamTitles
        heroTrailersEnabled = s.heroTrailersEnabled
        heroTrailerSound = s.heroTrailerSound
        suppressChange = false
        save()
    }

    private func load() {
        let raw = UserDefaults.standard.data(forKey: storageKey)
        let decodedBlob = raw.flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
        // A blob that exists but no longer decodes (a newer build's enum case,
        // say) is preserved before the defaults below get written over it on
        // this profile's first save.
        if let raw, decodedBlob == nil {
            UnreadableBlobGuard.preserve(raw, key: storageKey)
        }
        guard let decoded = decodedBlob else {
            // A profile with no saved blob must reset EVERY field, not just
            // order/disabled/titles/hideUnreleased: the presentation
            // prefs used to keep the previous profile's values and then got
            // written into the new profile's key on its first save — switching
            // to a fresh profile silently inherited (and stole) the old
            // profile's poster size, blur, CW sort, etc.
            orderKeys = []
            disabledKeys = []
            customTitles = [:]
            suppressChange = true
            hideUnreleasedContent = false
            applyPresentationDefaults()
            suppressChange = false
            return
        }
        orderKeys = decoded.orderKeys
        disabledKeys = Set(decoded.disabledKeys)
        customTitles = decoded.customTitles
        suppressChange = true
        hideUnreleasedContent = decoded.hideUnreleasedContent
        continueWatchingSortMode = decoded.continueWatchingSortMode ?? .recentlyWatched
        autoHideSidebar = decoded.autoHideSidebar ?? false
        fullStreamTitles = decoded.fullStreamTitles ?? false
        heroTrailersEnabled = decoded.heroTrailersEnabled ?? true
        heroTrailerSound = decoded.heroTrailerSound ?? false
        suppressChange = false
    }

    private func save() {
        // Bulk assigns (`load`, `applyRemotePresentation`) set `suppressChange`
        // and then write all ~22 published properties in a row, each with a
        // `didSet { save() }`. Without this the store re-encoded and re-wrote
        // the entire settings blob 22 times per apply — at launch, on every
        // profile switch, and on every sync that carried a preference change.
        // Both bulk paths call `save()` once themselves at the end.
        guard !suppressChange else { return }
        let persisted = Persisted(
            orderKeys: orderKeys,
            disabledKeys: Array(disabledKeys),
            customTitles: customTitles,
            hideUnreleasedContent: hideUnreleasedContent,
            continueWatchingSortMode: continueWatchingSortMode,
            autoHideSidebar: autoHideSidebar,
            fullStreamTitles: fullStreamTitles,
            heroTrailersEnabled: heroTrailersEnabled,
            heroTrailerSound: heroTrailerSound,
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
