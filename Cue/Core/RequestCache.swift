import Foundation
import CryptoKit

/// Coalesces concurrent identical requests: if the same key is already being
/// fetched, later callers await the SAME task instead of firing their own
/// network round-trip. Ported from the Android app's `inFlight*` maps in
/// MetaRepositoryImpl — without it, a Home screen (many rows) + focus-prefetch
/// + back-nav fire piles of duplicate requests for the same meta/catalog.
actor RequestCoalescer {
    private var inFlight: [String: Task<Data, Error>] = [:]

    func data(for key: String, _ work: @Sendable @escaping () async throws -> Data) async throws -> Data {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await work() }
        inFlight[key] = task
        let result = await task.result
        inFlight[key] = nil
        return try result.get()
    }
}

/// A thread-safe, disk-backed TTL cache of `Codable` values keyed by string.
/// Entries survive app relaunches (JSON in Caches/), with a small in-memory
/// layer on top so repeat reads in a session don't touch disk. Reads check
/// freshness against a caller-supplied TTL. Ported from the Android app's
/// DataStore caches (StreamLinkCache / enrichment) so re-opening a title is
/// instant instead of another addon sweep or meta fetch.
actor DiskCache<Value: Codable & Sendable> {
    private struct Entry: Codable { let value: Value; let time: Date }
    private let directory: URL
    private var memory: [String: Entry] = [:]
    /// The in-RAM mirror exists only to skip repeat disk reads within a
    /// session — uncapped it grows for the app's lifetime (every catalog /
    /// meta / enrichment response ever touched stays decoded in memory).
    /// Eviction is invisible: entries re-read from disk on the next hit.
    /// Tier-scaled: the "meta" cache's values are FULL-SERIES MetaItems —
    /// among the largest payloads in the app — and 64 of them decoded in RAM
    /// is not something the 2 GB box can idle on.
    private let memoryLimit = PerformanceProfile.isLowPower ? 16
        : PerformanceProfile.isMidPower ? 32 : 64

    private func capMemory() {
        guard memory.count > memoryLimit else { return }
        // Drop the oldest half so eviction is amortized, not per-insert.
        let sorted = memory.sorted { $0.value.time < $1.value.time }
        for (key, _) in sorted.prefix(memory.count - memoryLimit / 2) {
            memory.removeValue(forKey: key)
        }
    }

    init(name: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("CueCache/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One-time cleanup of the pre-rebrand cache dir, so it doesn't sit
        // orphaned on disk forever (it would never be read or evicted again).
        // Off-thread: several DiskCaches init during launch, and deleting a
        // potentially large directory synchronously there would block startup.
        let legacy = base.appendingPathComponent("NuvioCache", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: legacy)
            }
        }
    }

    /// Fresh value for `key`, or nil if missing/stale (`ttl <= 0` disables).
    func value(for key: String, ttl: TimeInterval) -> Value? {
        guard ttl > 0 else { return nil }
        let entry: Entry?
        if let hit = memory[key] {
            entry = hit
        } else if let data = try? Data(contentsOf: fileURL(key)),
                  let decoded = try? JSONDecoder().decode(Entry.self, from: data) {
            memory[key] = decoded
            capMemory()
            entry = decoded
        } else {
            entry = nil
        }
        guard let entry else { return nil }
        guard Date().timeIntervalSince(entry.time) < ttl else {
            // Stale: evict from BOTH layers. Nothing ever unlinked these, so
            // Caches/CueCache grew for the life of the install (full-series
            // MetaItem payloads included). A fresh request repopulates it.
            memory.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: fileURL(key))
            return nil
        }
        return entry.value
    }

    /// The value for `key` and its AGE, kept up to `keep` (stale-while-
    /// revalidate: the caller decides what's fresh). Older: deleted, nil.
    func entry(for key: String, keep: TimeInterval) -> (value: Value, age: TimeInterval)? {
        let entry: Entry?
        if let hit = memory[key] {
            entry = hit
        } else if let data = try? Data(contentsOf: fileURL(key)),
                  let decoded = try? JSONDecoder().decode(Entry.self, from: data) {
            memory[key] = decoded
            capMemory()
            entry = decoded
        } else {
            entry = nil
        }
        guard let entry else { return nil }
        let age = Date().timeIntervalSince(entry.time)
        guard age < keep else {
            memory.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: fileURL(key))
            return nil
        }
        return (entry.value, age)
    }

    func store(_ value: Value, for key: String) {
        let entry = Entry(value: value, time: Date())
        memory[key] = entry
        capMemory()
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let url = fileURL(key)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // The directory is created ONCE, in init. Anything that removes it
            // afterwards — Settings → "Clear cache" deletes every child of the
            // cache root and recreates only the root, and tvOS may reclaim
            // Caches/ under pressure — left every store() failing silently for
            // the rest of the session: catalogs, meta and stream results all
            // stopped being cached, with no symptom but a permanently slow app
            // until relaunch. Recreate and retry once.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func fileURL(_ key: String) -> URL {
        let hashed = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hashed).appendingPathExtension("json")
    }
}

/// RAW RESPONSES ON DISK, with their age (docs/LOADING-PLAN.md §2): the
/// bodies as they came (no re-encoding — a TMDB details body is ~44 KB), one
/// file each, the file's date as the time it was fetched. Reads hand back the
/// data AND its age: the caller decides what's fresh and what's only "still
/// usable while it refreshes" (stale-while-revalidate). Kept up to `keep`;
/// older files are deleted when met.
actor RawCache {
    static let tmdb = RawCache(name: "tmdb-raw")

    private let directory: URL
    private var memory: [String: (data: Data, time: Date)] = [:]
    private let memoryLimit = PerformanceProfile.isLowPower ? 24 : 96

    init(name: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("CueCache/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The body for `key` and how old it is — nil if missing or older than
    /// `keep`.
    func read(_ key: String, keep: TimeInterval) -> (data: Data, age: TimeInterval)? {
        let url = fileURL(key)
        let entry: (data: Data, time: Date)
        if let hit = memory[key] {
            entry = hit
        } else if let data = try? Data(contentsOf: url),
                  let time = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
            entry = (data, time)
            remember(key, entry)
        } else {
            return nil
        }
        let age = Date().timeIntervalSince(entry.time)
        guard age < keep else {
            memory.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (entry.data, age)
    }

    func write(_ key: String, _ data: Data) {
        remember(key, (data, Date()))
        let url = fileURL(key)
        if (try? data.write(to: url, options: .atomic)) == nil {
            // (The folder removed under us — "Clear cache", tvOS reclaiming
            // Caches/: recreate once.)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func remember(_ key: String, _ entry: (data: Data, time: Date)) {
        memory[key] = entry
        guard memory.count > memoryLimit else { return }
        for (old, _) in memory.sorted(by: { $0.value.time < $1.value.time }).prefix(memory.count - memoryLimit / 2) {
            memory.removeValue(forKey: old)
        }
    }

    private func fileURL(_ key: String) -> URL {
        let hashed = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hashed)
    }
}

/// A title's last search, for a few minutes — search, back out, search again
/// and the same list is there at once. In memory only, a fixed lifetime and
/// nothing else: after it, every search asks every add-on again (old debrid
/// links can stop working). Search Again skips it.
actor SourceListCache {
    static let shared = SourceListCache()
    static let lifetime: TimeInterval = 5 * 60

    private var lists: [String: (entries: [StreamEntry], time: Date)] = [:]

    init() {
        // The lists used to be kept on disk (and the last played link too):
        // clear what's left of them.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        Task.detached(priority: .utility) {
            for name in ["sources", "lastlink"] {
                try? FileManager.default.removeItem(at: base.appendingPathComponent("CueCache/\(name)"))
            }
        }
    }

    /// The title's list and when it was found, if still within `lifetime`.
    func list(for id: String) -> (entries: [StreamEntry], time: Date)? {
        lists = lists.filter { Date().timeIntervalSince($0.value.time) < Self.lifetime }
        return lists[id]
    }

    func store(_ entries: [StreamEntry], for id: String) {
        lists[id] = (entries, Date())
    }
}

// MARK: - Title records

/// One small record per title: what its text draws besides the catalog's —
/// a series' size, the dates its status is read from, TMDB's status and
/// tagline, MDBList's ratings. A few hundred bytes each, all of them in
/// one file, read into memory at launch (`load`, under the curtain): every
/// title seen before draws its badge, ratings and season count with its
/// text, never a moment after (one small file per kind, read async, came
/// late; an expired one waited for the network). Shown as they are, then
/// asked again once a day (`maxAge`): a new answer replaces them only
/// where it differs. Pictures are not here: `ImageCache`, shared by URL.
@MainActor
final class TitleRecords {
    static let shared = TitleRecords()

    struct Record: Codable {
        /// A series' seasons and episodes (specials left out).
        var size: TMDBService.ShowSize?
        /// The latest episode aired when the list was read, and the ones
        /// still to come: AIRING is read from them when shown, so it can't
        /// go stale between lookups.
        var lastAired: Date?
        var upcoming: [Date]?
        var showAt: Date?
        /// TMDB's: "ENDED", "ONGOING"…, and the tagline.
        var tmdbStatus: String?
        var tagline: String?
        var factsAt: Date?
        /// MDBList's (nil with a date: it has none).
        var ratings: MDBListRatings?
        var ratingsAt: Date?
        /// Last asked for: unused for `forgetAfter`, dropped.
        var usedAt: Date = Date()
    }

    enum Part { case show, facts, ratings }

    static let maxAge: TimeInterval = 24 * 60 * 60
    static let forgetAfter: TimeInterval = 60 * 24 * 60 * 60

    private var records: [String: Record] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private let file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CueCache/title-records.json")

    private init() {
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: Record].self, from: data) {
            let cutoff = Date().addingTimeInterval(-Self.forgetAfter)
            records = stored.filter { $0.value.usedAt > cutoff }
        }
        // (The separate caches these replace.)
        Task.detached(priority: .utility) {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            for name in ["show-sizes-v2", "series-status"] {
                try? FileManager.default.removeItem(at: base.appendingPathComponent("CueCache/\(name)"))
            }
        }
    }

    /// Read into memory (the launch, under the curtain).
    func load() { _ = records.count }

    /// Everything forgotten, in memory and on disk (Settings → Storage):
    /// asked again as titles are drawn.
    func clear() {
        records = [:]
        saveTask?.cancel()
        saveTask = nil
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Reading — at once, from memory

    func size(_ item: MetaItem) -> TMDBService.ShowSize? { records[item.id]?.size }
    func tagline(_ item: MetaItem) -> String? { records[item.id]?.tagline }
    /// nil: not known yet; `.some(nil)`: known to have none.
    func ratings(_ item: MetaItem) -> MDBListRatings?? {
        guard let record = records[item.id], record.ratingsAt != nil else { return nil }
        return .some(record.ratings)
    }

    /// - AIRING: an episode aired within `airingWindow`, or the next is due
    ///   within it.
    /// - ENDED + the year of its last episode: TMDB says ended or cancelled.
    /// - RETURNING: neither — between seasons (TMDB "Returning Series").
    /// Without TMDB (or until it's known), the catalog's years.
    func status(_ item: MetaItem) -> String? {
        guard item.isSeries, let record = records[item.id] else { return TitleBlock.catalogStatus(item) }
        let now = Date()
        let window = FixedFocusShowInfo.airingWindow
        let upcoming = record.upcoming ?? []
        let lastAired = ([record.lastAired].compactMap { $0 } + upcoming.filter { $0 <= now }).max()
        let nextDue = upcoming.filter { $0 > now }.min()
        if let lastAired, now.timeIntervalSince(lastAired) <= window { return "AIRING" }
        if let nextDue, nextDue.timeIntervalSince(now) <= window { return "AIRING" }
        switch record.tmdbStatus {
        case "ENDED":
            let year = lastAired.map { String(Calendar.current.component(.year, from: $0)) }
                ?? TitleBlock.catalogYears(item)?.end
            return year.map { "ENDED \($0)" } ?? "ENDED"
        case "ONGOING":
            return "RETURNING"
        default:
            return TitleBlock.catalogStatus(item)
        }
    }

    // MARK: Asking

    /// The parts missing or a day old asked again (each once at a time);
    /// returns once they're in. True when something shown changed.
    @discardableResult
    func refresh(_ item: MetaItem, _ parts: Set<Part>) async -> Bool {
        let before = records[item.id]
        var record = before ?? Record()
        record.usedAt = Date()
        records[item.id] = record
        let stale = { (at: Date?) in at.map { Date().timeIntervalSince($0) > Self.maxAge } ?? true }
        let settings = MDBListSettingsStore.current
        await withTaskGroup(of: Void.self) { group in
            if parts.contains(.show), item.isSeries, stale(record.showAt) {
                group.addTask { await self.once(item.id + ":show") { await self.askShow(item) } }
            }
            if parts.contains(.facts), TMDBService.hasAPIKey, stale(record.factsAt) {
                group.addTask { await self.once(item.id + ":facts") { await self.askFacts(item) } }
            }
            if parts.contains(.ratings), settings.isConfigured, settings.showsRatings(onDetails: false),
               stale(record.ratingsAt) {
                group.addTask { await self.once(item.id + ":ratings") { await self.askRatings(item, settings) } }
            }
        }
        let after = records[item.id]
        if before == nil || after?.size != before?.size || after?.ratings != before?.ratings
            || after?.tagline != before?.tagline || after?.tmdbStatus != before?.tmdbStatus
            || after?.lastAired != before?.lastAired || after?.upcoming != before?.upcoming {
            scheduleSave()
            return true
        }
        scheduleSave()
        return false
    }

    private func once(_ key: String, _ work: @escaping @MainActor () async -> Void) async {
        if let task = running[key] { return await task.value }
        let task = Task { @MainActor in await work() }
        running[key] = task
        await task.value
        running[key] = nil
    }

    private func askShow(_ item: MetaItem) async {
        guard let addonManager = AddonManager.shared else { return }
        let meta = await SeriesEpisodes.fullMeta(for: item, addonManager: addonManager)
        // (No list: asked again next time, what's known kept.)
        guard let size = SeriesEpisodes.size(of: meta) else { return }
        let now = Date()
        let dates = (meta.videos ?? []).filter { ($0.season ?? 0) > 0 }.compactMap(\.airedDate)
        var record = records[item.id] ?? Record()
        record.size = size
        record.lastAired = dates.filter { $0 <= now }.max()
        record.upcoming = dates.filter { $0 > now }.sorted()
        record.showAt = now
        records[item.id] = record
    }

    private func askFacts(_ item: MetaItem) async {
        guard let facts = await TMDBService.facts(for: item) else { return }
        var record = records[item.id] ?? Record()
        record.tmdbStatus = facts.status
        record.tagline = facts.tagline
        record.factsAt = Date()
        records[item.id] = record
    }

    private func askRatings(_ item: MetaItem, _ settings: MDBListSettings) async {
        _ = await MDBListService.ratings(for: item, settings: settings)
        // (nil from the service is "none" and "failed" alike: only an
        // answer it has kept counts.)
        guard let known = MDBListService.cachedRatings(for: item) else { return }
        var record = records[item.id] ?? Record()
        record.ratings = known
        record.ratingsAt = Date()
        records[item.id] = record
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            saveTask = nil
            let snapshot = records
            let file = file
            Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}

/// WHAT CUE KEEPS ON DISK, by kind, and one clear for all of it
/// (Settings → Storage). Every cache, honestly: pictures, the add-ons'
/// and TMDB's answers, the titles' records and ratings, trailers' links,
/// the network's own response cache, and what playback left in `tmp`.
/// Not caches, never cleared: the account, profiles, progress, library,
/// collections, settings.
enum CacheStorage {
    struct Part: Identifiable, Sendable {
        let id: String
        let name: String
        let bytes: Int64
        /// Its allowance on disk, where it has one (older entries go past it).
        let limit: Int64?
    }

    private static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
    private static var cue: URL { caches.appendingPathComponent("CueCache", isDirectory: true) }
    private static var responses: URL {
        caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.cue.tv", isDirectory: true)
    }
    private static let addonFiles = ["meta"]
    private static let tmdbFiles = ["tmdb-raw", "tmdb-imdb-ids", "tmdb-facts", "tmdb-traits", "cue-rows"]
    private static let ratingFiles = ["title-records.json", "mdblist-ratings-v2"]
    private static let trailerFiles = ["trailers.json"]
    /// In CueCache but not a cache: kept.
    private static func kept(_ name: String) -> Bool {
        name == "collections-library.json" || name.hasPrefix("background-")
    }
    /// The network's response cache (URLCache's database and bodies; not
    /// the system's shader cache beside them).
    private static func isResponse(_ name: String) -> Bool {
        name.hasPrefix("Cache.db") || name == "fsCachedData"
    }
    private static func isPlayback(_ name: String) -> Bool {
        PlayerTempSweep.scratchPrefixes.contains(where: name.hasPrefix) || name.hasPrefix(PlayerTempSweep.spoolPrefix)
    }
    /// The responses' allowance: the add-ons' session's and TMDB's.
    static let responseLimit: Int64 = (256 + 128) << 20
    /// The player's disk window, at most (a quarter of free space).
    static let playbackLimit: Int64 = 6 << 30

    /// Each kind's size, off the main thread.
    static func measure() async -> [Part] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let cueNames = (try? fm.contentsOfDirectory(atPath: cue.path)) ?? []
            func size(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + allocated($1, fm) } }
            func inCue(_ names: [String]) -> Int64 { size(names.map { cue.appendingPathComponent($0) }) }
            let known = Set(addonFiles + tmdbFiles + ratingFiles + trailerFiles)
            let other = cueNames.filter { !known.contains($0) && !kept($0) }
            let responseNames = ((try? fm.contentsOfDirectory(atPath: responses.path)) ?? []).filter(isResponse)
            let tmp = fm.temporaryDirectory
            let playbackNames = ((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []).filter(isPlayback)
            var parts = [
                Part(id: "pictures", name: "Pictures", bytes: size([ImageCache.diskFolder]),
                     limit: Int64(ImageCache.diskLimit)),
                Part(id: "addons", name: "Add-on Data",
                     bytes: inCue(addonFiles) + size([caches.appendingPathComponent("cue-home-catalogs.json")]),
                     limit: nil),
                Part(id: "tmdb", name: "TMDB Data", bytes: inCue(tmdbFiles), limit: nil),
                Part(id: "ratings", name: "Ratings & Badges", bytes: inCue(ratingFiles), limit: nil),
                Part(id: "trailers", name: "Trailers", bytes: inCue(trailerFiles), limit: nil),
                Part(id: "responses", name: "Network Responses",
                     bytes: size(responseNames.map { responses.appendingPathComponent($0) }), limit: responseLimit),
                Part(id: "playback", name: "Playback Files",
                     bytes: size(playbackNames.map { tmp.appendingPathComponent($0) }), limit: playbackLimit),
            ]
            let otherBytes = inCue(other)
            if otherBytes > 0 { parts.append(Part(id: "other", name: "Other", bytes: otherBytes, limit: nil)) }
            return parts
        }.value
    }

    /// Free space on this Apple TV.
    static func available() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// All of it cleared. What's in memory for this session stays where
    /// clearing it would empty what's on screen (pictures); the records go
    /// too (asked again as titles are drawn).
    @MainActor
    static func clear() async {
        await ImageCache.shared.clearDisk()
        TitleRecords.shared.clear()
        TrailerResolver.clearChoices()
        for session in [StremioAPI.session, TMDBService.session, MDBListService.session] {
            session.configuration.urlCache?.removeAllCachedResponses()
        }
        URLCache.shared.removeAllCachedResponses()
        let playing = PlayerController.isPlaying
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: cue.path)) ?? [] where !kept(name) {
                let url = cue.appendingPathComponent(name)
                var directory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                    // Emptied, not removed: the disk caches write into it.
                    for file in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                        try? fm.removeItem(at: file)
                    }
                } else {
                    try? fm.removeItem(at: url)
                }
            }
            try? fm.removeItem(at: caches.appendingPathComponent("cue-home-catalogs.json"))
            if !playing { PlayerTempSweep.sweep() }
        }.value
    }

    private static func allocated(_ url: URL, _ fm: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let file = walker?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
