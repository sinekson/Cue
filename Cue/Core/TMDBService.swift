import Foundation
import UIKit

/// TMDB settings, mirroring the Android `TmdbSettings`. Persisted locally;
/// governs metadata enrichment and whether TMDB collection sources resolve.
struct TMDBSettings: Codable, Equatable {
    var enabled: Bool = false
    var enrichContinueWatching: Bool = true
    var language: String = "en"
    // Granular enrichment toggles (mirror Android's per-section TMDB switches).
    var useCredits: Bool = true
    var useTrailers: Bool = true
    var useMoreLikeThis: Bool = true
    /// Country / spoken-language detail fields.
    var useDetails: Bool = true
    /// Release-date field.
    var useReleaseDates: Bool = true
    /// Production companies row.
    var useProductions: Bool = true
    /// Collection ("part of…") row and its parts.
    var useCollections: Bool = true
    /// Per-episode ratings + air dates.
    var useEpisodes: Bool = true
    /// The viewer's OWN TMDB v3 API key. There is no app-embedded key any
    /// more — TMDB keys are per-account and free, and one shared key meant
    /// every install competed for the same rate limit. Optional so blobs
    /// written before this field existed (and by other Cue clients) still
    /// decode; nil and "" both mean "not configured".
    var apiKey: String?

    static let `default` = TMDBSettings()

    /// Trimmed key, or "" when unset.
    var trimmedAPIKey: String {
        (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// TMDB can answer: a key means on. (`enabled` and the `use…` switches
    /// are only kept for the account's settings round-trip — Cue has no
    /// switches for them.)
    var isUsable: Bool { !trimmedAPIKey.isEmpty }
}

@MainActor
final class TMDBSettingsStore: ObservableObject {
    @Published var settings: TMDBSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            TMDBService.preferredLanguage = settings.language
            TMDBService.apiKey = settings.trimmedAPIKey
            if !applyingRemote { onLocalChange?() }
        }
    }

    /// Fired on a local (user-driven) change so the sync manager can push it up.
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    private static let key = "cue.tmdb.settings.v1"

    /// PER PROFILE (upstream scopes `tmdb_settings` per profile): each profile
    /// keeps its own language, enrichment switches — and, on tvOS, its own
    /// key, since keys here are the viewer's personal TMDB login. The legacy
    /// device-wide blob (key included) goes to the PRIMARY profile; other
    /// profiles start unconfigured and enter their own key in Settings →
    /// Integrations → TMDB (Trakt-switch semantics).
    private(set) var profileID: Int

    init() {
        profileID = ProfileScopedDefaults.activeProfileID
        settings = Self.load(profile: profileID)
        // A key that predates "a key means on" — flip it on rather than leaving
        // the viewer with a configured, silent TMDB.
        if !settings.enabled, !settings.trimmedAPIKey.isEmpty { settings.enabled = true }
        // Localize every TMDB request from launch (get() reads this global).
        TMDBService.preferredLanguage = settings.language
        // Same for the key: every request reads it off the service.
        TMDBService.apiKey = settings.trimmedAPIKey
    }

    private static func load(profile: Int) -> TMDBSettings {
        if let data = ProfileScopedDefaults.data(key, profile),
           let decoded = try? JSONDecoder().decode(TMDBSettings.self, from: data) {
            return decoded
        }
        return .default
    }

    /// Point the store at a profile. The `settings` didSet re-points the
    /// service globals (key + language), so requests speak for the new
    /// profile immediately.
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        applyingRemote = true
        settings = Self.load(profile: id)
        applyingRemote = false
    }

    func forgetProfile(_ id: Int) {
        ProfileScopedDefaults.forget([Self.key], profile: id)
        if id == profileID {
            applyingRemote = true
            settings = Self.load(profile: id)
            applyingRemote = false
        }
    }

    /// Save a key. Turning TMDB on is part of saving one: there is no reason to
    /// enter a key except to use it, and the extra switch was a trap.
    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = settings
        next.apiKey = trimmed
        if !trimmed.isEmpty { next.enabled = true }
        settings = next
    }

    /// Apply settings pulled from the account without echoing them back up.
    func applyRemote(_ new: TMDBSettings) {
        var new = new
        // Never let a remote blob ERASE the key. Older clients (and Android)
        // write this struct without an `apiKey` field at all, so taking the
        // remote value wholesale would wipe the key this device just had
        // typed into it the moment any other device pushed its preferences.
        // A remote key that IS present is a real change and wins.
        if new.trimmedAPIKey.isEmpty {
            new.apiKey = settings.apiKey
            // ...and neither can it meaningfully say whether TMDB is ON. A
            // client that knows nothing about per-viewer keys writes its own
            // `enabled`, and letting that land would switch TMDB off for every
            // collection here on the next sync, for no reason the viewer could
            // see. An explicit off still syncs from any client that carries a
            // key, which is every client that can actually use TMDB.
            new.enabled = settings.enabled
        }
        guard new != settings else { return }
        applyingRemote = true
        settings = new
        applyingRemote = false
    }

    /// Enabled AND configured. Callers gate TMDB features on this, so turning
    /// the switch on without a key never advertises sources that can't load.
    var isEnabled: Bool { settings.isUsable }

    /// Whether a key is set at all, regardless of the enable switch.
    var hasAPIKey: Bool { !settings.trimmedAPIKey.isEmpty }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(
            data, forKey: ProfileScopedDefaults.key(Self.key, profileID))
    }
}

/// Thin TMDB v3 client. The API key is the VIEWER's own — entered in
/// Settings → Integrations → TMDB and pushed here by `TMDBSettingsStore`.
/// There is no shared app key: keys are free, per-account, and rate-limited
/// per key, so one embedded key throttled everybody at once. With no key set
/// every request fails fast with `.missingKey` and the features that depend on
/// TMDB simply stay empty. Used to resolve TMDB collection sources into
/// MetaItems and to map TMDB ids to IMDB ids so those items flow through the
/// existing Cinemeta detail/stream pipeline.
enum TMDBService {
    /// The viewer's TMDB v3 key. Read by every request on whatever task it
    /// runs and written by the settings store on main, so it is lock-guarded
    /// exactly like `preferredLanguage` below.
    private static let keyLock = NSLock()
    nonisolated(unsafe) private static var apiKeyStorage = ""
    static var apiKey: String {
        get { keyLock.lock(); defer { keyLock.unlock() }; return apiKeyStorage }
        set { keyLock.lock(); defer { keyLock.unlock() }; apiKeyStorage = newValue }
    }

    /// Whether TMDB can be called at all. Callers that want to skip work
    /// entirely (rather than eat a thrown `.missingKey`) check this first.
    static var hasAPIKey: Bool { !apiKey.isEmpty }
    private static let base = "https://api.themoviedb.org/3"
    private static let imageBase = "https://image.tmdb.org/t/p"

    /// Plain "yyyy-MM-dd" for TMDB's date-range discover params. Fixed UTC/
    /// POSIX locale so it never reflects the device's calendar/locale.
    private static let isoDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .useProtocolCachePolicy
        // Memory side tier-scaled: 16 MB of cached response bodies held in
        // RAM is real money on the 2 GB box; the disk side is cheap.
        config.urlCache = URLCache(
            memoryCapacity: PerformanceProfile.isLowPower ? (4 << 20)
                : PerformanceProfile.isMidPower ? (8 << 20) : (16 << 20),
            diskCapacity: 128 << 20)
        return URLSession(configuration: config)
    }()

    /// The answers kept on disk, and room for them (Settings → TMDB).
    static var cacheUsage: (disk: Int, capacity: Int) {
        let cache = session.configuration.urlCache
        return (cache?.currentDiskUsage ?? 0, cache?.diskCapacity ?? 0)
    }

    static func clearCache() {
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    // Cache TMDB→IMDB id lookups so repeated collection loads stay cheap.
    // Guarded by `cacheLock` — these caches are read/written from many
    // concurrent `Task`s (catalog rows map items in parallel), and a plain
    // Swift Dictionary is not thread-safe (concurrent mutation → EXC_BAD_ACCESS).
    private static let cacheLock = NSLock()
    private static var imdbCache: [String: String] = [:]
    private static var contentRatingCache: [String: String] = [:]
    private static var seasonEpisodeCache: [String: [Int: EpisodeExtra]] = [:]
    private static var episodeCastCache: [String: [CastMember]] = [:]

    /// Per-dictionary entry ceilings. These caches used to grow unbounded for
    /// the process lifetime; the two fat ones (season episode maps with
    /// overview text + still paths, episode cast lists) accumulate low MBs
    /// over a long couch session on a 2 GB box. When one hits its cap, half
    /// of it is dropped (arbitrary half — the entries are cheap to refetch),
    /// the same policy StremioResponseCache uses. The id maps are tiny per
    /// row and capped loosely.
    private static let idCacheLimit = 4096
    private static let fatCacheLimit = 256
    private static func capped<K, V>(_ dict: inout [K: V], limit: Int) {
        guard dict.count > limit else { return }
        for key in Array(dict.keys.prefix(dict.count - limit / 2)) {
            dict.removeValue(forKey: key)
        }
    }

    /// Emptied on memory warning — each entry is one cheap request away.
    private static let cachePurgeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil, queue: .main
    ) { _ in
        cacheLock.lock(); defer { cacheLock.unlock() }
        seasonEpisodeCache.removeAll()
        episodeCastCache.removeAll()
        trailerKeyCache.removeAll()
        // The id maps stay: a few bytes per row, and they save the paired
        // find/rating round trips that make collection loads cheap.
    }

    private static func cachedIMDB(_ key: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return imdbCache[key]
    }
    private static func storeIMDB(_ value: String, for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        capped(&imdbCache, limit: idCacheLimit)
        imdbCache[key] = value
    }
    private static func cachedContentRating(_ key: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return contentRatingCache[key]
    }
    private static func storeContentRating(_ value: String?, for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        capped(&contentRatingCache, limit: idCacheLimit)
        contentRatingCache[key] = value ?? ""
    }
    private static func cachedSeasonEpisodes(_ key: String) -> [Int: EpisodeExtra]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return seasonEpisodeCache[key]
    }
    private static func storeSeasonEpisodes(_ value: [Int: EpisodeExtra], for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        _ = cachePurgeObserver
        capped(&seasonEpisodeCache, limit: fatCacheLimit)
        seasonEpisodeCache[key] = value
    }
    private static func cachedEpisodeCast(_ key: String) -> [CastMember]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return episodeCastCache[key]
    }
    private static func storeEpisodeCast(_ value: [CastMember], for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        _ = cachePurgeObserver
        capped(&episodeCastCache, limit: fatCacheLimit)
        episodeCastCache[key] = value
    }
    private static func cachedFind(_ key: String) -> (Int, Bool)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return findCache[key]
    }
    private static func storeFind(_ value: (Int, Bool), for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        capped(&findCache, limit: idCacheLimit)
        findCache[key] = value
    }

    enum TMDBError: LocalizedError {
        case badResponse(Int)
        case missing
        case badPath(String)
        case missingKey
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "TMDB returned HTTP \(code)"
            case .missing: return "TMDB item not found"
            case .badPath(let path): return "TMDB request path is not a valid URL: \(path)"
            case .missingKey: return "No TMDB API key — add yours in Settings → Integrations → TMDB"
            }
        }
    }

    /// Preferred content language (ISO-639-1), kept in sync with the TMDB
    /// language setting so EVERY request is localized — not just the calls
    /// that happened to thread a `language:` argument. Set once at launch and
    /// on change by TMDBSettingsStore.
    /// Read by every TMDB request on whatever task it runs, written by the
    /// settings store on main — guarded, so a language change can never tear a
    /// concurrent read.
    private static let languageLock = NSLock()
    nonisolated(unsafe) private static var preferredLanguageStorage = "en"
    static var preferredLanguage: String {
        get { languageLock.lock(); defer { languageLock.unlock() }; return preferredLanguageStorage }
        set { languageLock.lock(); defer { languageLock.unlock() }; preferredLanguageStorage = newValue }
    }

    /// Same timing shell as `StremioAPI.get`, and for the same reason: every
    /// TMDB call in the app comes through here, so one wrapper answers which
    /// enrichment was slow or missing without a probe per endpoint. `path`
    /// alone is logged — the query carries the API key.
    private static func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let done = AppProbe.begin("data", "tmdb " + path)
        do {
            let value: T = try await fetch(path, query: query)
            done("ok")
            return value
        } catch {
            done("FAILED")
            AppProbe.warn("tmdb", "\(path) — \(error)")
            throw error
        }
    }

    private static func fetch<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await fetchData(path, query: query))
    }

    // MARK: Stale-while-revalidate (docs/LOADING-PLAN.md §2)

    /// A request answered from DISK when it can be: what's there is returned
    /// at once — and, older than `fresh(value)`, fetched again in the
    /// background for next time (the screen keeps what it has; TMDB data
    /// changes slowly). Kept up to `keep`. One request per question: callers
    /// asking at the same time share it.
    private static func cachedGet<T: Decodable>(
        _ path: String, query: [String: String] = [:],
        fresh: @escaping (T) -> TimeInterval, keep: TimeInterval
    ) async throws -> T {
        let key = cacheKey(path, query)
        if let (data, age) = await RawCache.tmdb.read(key, keep: keep),
           let value = try? JSONDecoder().decode(T.self, from: data) {
            if age > fresh(value) {
                Task.detached(priority: .utility) { _ = try? await shared(key, path, query) }
            }
            return value
        }
        return try JSONDecoder().decode(T.self, from: try await shared(key, path, query))
    }

    /// The request behind a cache key — one at a time per key — written to
    /// disk when it comes back.
    private static func shared(_ key: String, _ path: String, _ query: [String: String]) async throws -> Data {
        // (Looked up and started in one step: two callers never both start it.)
        let task: Task<Data, Error> = inFlightLock.withLock {
            if let running = inFlight[key] { return running }
            let task = Task<Data, Error> {
                defer { inFlightLock.withLock { inFlight[key] = nil } }
                let done = AppProbe.begin("data", "tmdb " + path)
                do {
                    let data = try await fetchData(path, query: query)
                    await RawCache.tmdb.write(key, data)
                    done("ok")
                    return data
                } catch {
                    done("FAILED")
                    throw error
                }
            }
            inFlight[key] = task
            return task
        }
        return try await task.value
    }
    static let day: TimeInterval = 24 * 60 * 60
    private static let inFlightLock = NSLock()
    nonisolated(unsafe) private static var inFlight: [String: Task<Data, Error>] = [:]

    /// The request as a key: path, the parameters in a FIXED order, the
    /// language the request goes out in.
    private static func cacheKey(_ path: String, _ query: [String: String]) -> String {
        let lang = query["language"] ?? preferredLanguage
        let items = query.filter { $0.key != "language" }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(path)?\(items)#\(lang)"
    }

    private static func fetchData(_ path: String, query: [String: String] = [:]) async throws -> Data {
        // No key, no request. Every TMDB v3 endpoint needs one, and firing
        // them anyway would just spend the network on guaranteed 401s.
        let key = apiKey
        guard !key.isEmpty else { throw TMDBError.missingKey }
        // `path` embeds ids that come from add-ons, Trakt and synced rows (e.g.
        // /find/<imdbID>) and URLComponents(string:) is strict — an id carrying
        // a space or any other illegal character made this force-unwrap TRAP,
        // taking the app down over one bad row. Escape what we can, then fail as
        // an ordinary error rather than crashing.
        guard var comps = URLComponents(string: base + path)
            ?? path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                .flatMap({ URLComponents(string: base + $0) })
        else { throw TMDBError.badPath(path) }
        var items = [URLQueryItem(name: "api_key", value: key)]
        // Localize any request that didn't specify a language explicitly.
        if query["language"] == nil, preferredLanguage != "en" {
            items.append(URLQueryItem(name: "language", value: preferredLanguage))
        }
        // In a FIXED order: a Dictionary's changes per launch, which made the
        // same request a different URL every time — the HTTP cache missed.
        items += query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        guard let url = comps.url else { throw TMDBError.badPath(path) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TMDBError.badResponse(http.statusCode)
        }
        return data
    }

    /// Check a key before saving it, so a typo says so on the spot instead of
    /// silently emptying every TMDB-backed row. `/configuration` is the
    /// cheapest authenticated endpoint TMDB has.
    static func validate(apiKey candidate: String) async -> Bool {
        await check(apiKey: candidate) == true
    }

    /// Whether TMDB takes the key; nil when TMDB couldn't be reached.
    static func check(apiKey candidate: String) async -> Bool? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, var comps = URLComponents(string: base + "/configuration")
        else { return false }
        comps.queryItems = [URLQueryItem(name: "api_key", value: key)]
        guard let url = comps.url,
              let (_, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return nil }
        return (200..<300).contains(http.statusCode)
    }

    private static func imageURL(_ path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return "\(imageBase)/\(size)\(path)"
    }

    /// Upgrade a stored TMDB image URL (…/t/p/w500/…) to full-resolution
    /// `original`, so brand logos render crisp on a big TV. Non-TMDB URLs (and
    /// already-`original` ones) pass through untouched.
    static func originalSize(_ urlString: String?) -> String? {
        guard let urlString, urlString.contains("image.tmdb.org") else { return urlString }
        return urlString.replacingOccurrences(
            of: "/t/p/w[0-9]+/", with: "/t/p/original/", options: .regularExpression)
    }

    // MARK: - ID mapping

    /// TMDB id -> IMDb id is a PERMANENT mapping, so it is worth keeping across
    /// launches. In memory only, every relaunch re-resolved every id from
    /// scratch — and this sits in front of first paint on a collection page.
    private static let imdbDiskCache = DiskCache<String>(name: "tmdb-imdb-ids")
    private static let imdbDiskTTL: TimeInterval = 90 * 24 * 60 * 60
    /// Two folders containing the same title fired two simultaneous lookups,
    /// because the in-memory cache is only written once a response lands.
    private actor IMDbCoalescer {
        private var inFlight: [String: Task<String?, Never>] = [:]

        func resolve(_ key: String, _ work: @Sendable @escaping () async -> String?) async -> String? {
            if let existing = inFlight[key] { return await existing.value }
            let task = Task { await work() }
            inFlight[key] = task
            let value = await task.value
            inFlight[key] = nil
            return value
        }
    }
    private static let imdbCoalescer = IMDbCoalescer()

    /// Map a TMDB id to an IMDB tt id via /external_ids. Cached; nil on failure.
    static func imdbID(tmdbID: Int, isMovie: Bool) async -> String? {
        let cacheKey = "\(isMovie ? "m" : "t"):\(tmdbID)"
        if let hit = cachedIMDB(cacheKey) { return hit.isEmpty ? nil : hit }
        if let stored = await imdbDiskCache.value(for: cacheKey, ttl: imdbDiskTTL) {
            storeIMDB(stored, for: cacheKey)
            return stored.isEmpty ? nil : stored
        }
        let path = isMovie ? "/movie/\(tmdbID)/external_ids" : "/tv/\(tmdbID)/external_ids"
        struct ExternalIDs: Decodable { let imdb_id: String? }
        // Coalesced on the cache key so concurrent callers share one round trip.
        // "TMDB says there is no IMDb id" and "the request failed" are NOT
        // the same answer. Storing "" for a 429/offline/timeout pinned the
        // title to its `tmdb:` id for 90 days across relaunches — no streams,
        // no sync matching, and nothing ever retried it. Only a response that
        // arrived may write the negative entry.
        // nil = the request failed (cache nothing); "" = TMDB answered and
        // the title has no IMDb id (a real negative, cached).
        let outcome: String? = await imdbCoalescer.resolve(cacheKey) {
            guard let ids = try? await get(path) as ExternalIDs else { return nil }
            return ids.imdb_id ?? ""
        }
        guard let imdb = outcome else { return nil }
        storeIMDB(imdb, for: cacheKey)
        await imdbDiskCache.store(imdb, for: cacheKey)
        return imdb.isEmpty ? nil : imdb
    }

    /// Resolve an IMDb `tt…` id through TMDB. This is a fallback for newer or
    /// upcoming titles that Cinemeta can miss, preventing saved/synced rows from
    /// displaying only the raw IMDb id.
    static func metaItem(imdbID: String, type: String) async -> MetaItem? {
        guard imdbID.hasPrefix("tt") else { return nil }
        struct FindResponse: Decodable {
            struct Movie: Decodable {
                let id: Int
                let title: String?
                let poster_path: String?
                let backdrop_path: String?
                let overview: String?
                let release_date: String?
                let vote_average: Double?
            }
            struct TV: Decodable {
                let id: Int
                let name: String?
                let poster_path: String?
                let backdrop_path: String?
                let overview: String?
                let first_air_date: String?
                let vote_average: Double?
            }
            let movie_results: [Movie]?
            let tv_results: [TV]?
        }
        guard let body: FindResponse = try? await get(
            "/find/\(imdbID)",
            query: ["external_source": "imdb_id"]
        ) else { return nil }

        let preferredType = type.lowercased()
        if ["series", "tv", "show", "tvshow"].contains(preferredType), let show = body.tv_results?.first, let name = show.name, !name.isEmpty {
            return MetaItem(
                id: imdbID,
                type: "series",
                name: name,
                poster: imageURL(show.poster_path, size: "w500") ?? imageURL(show.backdrop_path, size: "w780"),
                background: imageURL(show.backdrop_path, size: "original"),
                logo: nil,
                description: show.overview,
                releaseInfo: show.first_air_date.map { String($0.prefix(4)) },
                imdbRating: show.vote_average.map { String(format: "%.1f", $0) },
                genres: nil
            )
        }
        if let movie = body.movie_results?.first, let title = movie.title, !title.isEmpty {
            return MetaItem(
                id: imdbID,
                type: "movie",
                name: title,
                poster: imageURL(movie.poster_path, size: "w500") ?? imageURL(movie.backdrop_path, size: "w780"),
                background: imageURL(movie.backdrop_path, size: "original"),
                logo: nil,
                description: movie.overview,
                releaseInfo: movie.release_date.map { String($0.prefix(4)) },
                imdbRating: movie.vote_average.map { String(format: "%.1f", $0) },
                genres: nil
            )
        }
        if let show = body.tv_results?.first, let name = show.name, !name.isEmpty {
            return MetaItem(
                id: imdbID,
                type: "series",
                name: name,
                poster: imageURL(show.poster_path, size: "w500") ?? imageURL(show.backdrop_path, size: "w780"),
                background: imageURL(show.backdrop_path, size: "original"),
                logo: nil,
                description: show.overview,
                releaseInfo: show.first_air_date.map { String($0.prefix(4)) },
                imdbRating: show.vote_average.map { String(format: "%.1f", $0) },
                genres: nil
            )
        }
        return nil
    }

    // MARK: - Collection source discovery (editor: search / id lookup)

    struct CompanySearchResult: Identifiable, Hashable {
        let id: Int
        let name: String
        let logoURL: String?
    }

    /// TMDB has no company-name matching in `/search/company` beyond substring,
    /// but that's exactly what the editor needs to let a user find "Marvel" etc.
    static func searchCompanies(_ query: String) async -> [CompanySearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        struct Response: Decodable {
            struct Item: Decodable { let id: Int; let name: String; let logo_path: String? }
            let results: [Item]
        }
        guard let body: Response = try? await get("/search/company", query: ["query": trimmed]) else { return [] }
        return body.results.prefix(20).map {
            CompanySearchResult(id: $0.id, name: $0.name, logoURL: imageURL($0.logo_path, size: "w300"))
        }
    }

    struct PersonSearchResult: Identifiable, Hashable {
        let id: Int
        let name: String
        let profileURL: String?
        let knownFor: String?
        /// TMDB's popularity, and the votes of their best-known title (for
        /// Search's own order).
        var popularity: Double = 0
        var knownForVotes: Int = 0
    }

    static func searchPeople(_ query: String) async -> [PersonSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        struct Response: Decodable {
            struct Item: Decodable {
                let id: Int; let name: String; let profile_path: String?
                let known_for_department: String?
                let popularity: Double?
                struct Title: Decodable { let vote_count: Int? }
                let known_for: [Title]?
            }
            let results: [Item]
        }
        guard let body: Response = try? await get("/search/person", query: ["query": trimmed]) else { return [] }
        return body.results.prefix(20).map {
            PersonSearchResult(id: $0.id, name: $0.name,
                               profileURL: imageURL($0.profile_path, size: "w300"),
                               knownFor: $0.known_for_department,
                               popularity: $0.popularity ?? 0,
                               knownForVotes: $0.known_for?.compactMap(\.vote_count).max() ?? 0)
        }
    }

    /// TMDB has no network SEARCH endpoint — only lookup by id (matches
    /// Android, which requires the id and fetches the name for confirmation).
    static func networkName(id: Int) async -> String? {
        struct Response: Decodable { let name: String? }
        return (try? await get("/network/\(id)") as Response)?.name
    }

    struct BrandInfo { let name: String; let logoURL: String? }

    /// Network name + logo (for Community Collections tiles — official HQ art,
    /// fetched live so it's never stale even if TMDB reshuffles a logo).
    /// Widest logo variant (ratio ≥ 1.5) from a company/network's alternative
    /// logos. Some brands' PRIMARY mark is squarish (Warner Bros' shield,
    /// ratio ~1.1), which lands a mismatched square tile in an otherwise
    /// landscape row — but TMDB usually also hosts the wide wordmark banner
    /// (WB's is 1280×331). Highest-resolution wide variant wins; nil when the
    /// brand has no wide logo at all.
    static func brandWideLogo(id: Int, isNetwork: Bool) async -> String? {
        struct ImagesResponse: Decodable { let logos: [Logo]? }
        struct Logo: Decodable { let file_path: String?; let aspect_ratio: Double?; let width: Int? }
        let path = isNetwork ? "/network/\(id)/images" : "/company/\(id)/images"
        guard let body: ImagesResponse = try? await get(path, query: [:]) else { return nil }
        return (body.logos ?? [])
            .filter { ($0.aspect_ratio ?? 0) >= 1.5 }
            .sorted { ($0.width ?? 0) > ($1.width ?? 0) }
            .first
            .flatMap { imageURL($0.file_path, size: "w500") }
    }

    /// A title's picture for the billboard and Details: TMDB's main backdrop
    /// (TMDB's own choice, by votes), the original file. (Tried: one of
    /// several at random each time — the others too often looked bad, by
    /// whatever rule: the best by average, by votes, bars on both.) nil:
    /// none, or not asked (no key, an id TMDB can't map, the request failed).
    static func backdrop(id: String, type: String) async -> String? {
        guard hasAPIKey, let (tmdbID, isMovie) = await resolveTMDBID(from: id, type: type) else { return nil }
        struct Response: Decodable { let backdrop_path: String? }
        let path = (isMovie ? "/movie/" : "/tv/") + "\(tmdbID)"
        guard let body: Response = try? await cachedGet(path, query: [:], fresh: { _ in 7 * day }, keep: 60 * day),
              let file = body.backdrop_path
        else { return nil }
        return imageURL(file, size: "original")
    }

    static func networkBrand(id: Int) async -> BrandInfo? {
        struct Response: Decodable { let name: String?; let logo_path: String? }
        guard let body: Response = try? await get("/network/\(id)"), let name = body.name else { return nil }
        return BrandInfo(name: name, logoURL: imageURL(body.logo_path, size: "w500"))
    }

    /// Company name + logo, same purpose as `networkBrand` for studios.
    static func companyBrand(id: Int) async -> BrandInfo? {
        struct Response: Decodable { let name: String?; let logo_path: String? }
        guard let body: Response = try? await get("/company/\(id)"), let name = body.name else { return nil }
        return BrandInfo(name: name, logoURL: imageURL(body.logo_path, size: "w500"))
    }

    static func collectionName(id: Int, language: String) async -> String? {
        struct Response: Decodable { let name: String? }
        return (try? await get("/collection/\(id)", query: ["language": language]) as Response)?.name
    }

    static func listName(id: Int, language: String) async -> String? {
        struct Response: Decodable { let name: String? }
        return (try? await get("/list/\(id)", query: ["language": language]) as Response)?.name
    }

    /// Parse a bare numeric id, or the id embedded in a themoviedb.org URL
    /// (`/list/123-slug`, `/collection/456-slug`) — mirrors the Android app's
    /// tolerant input so pasting either a URL or a plain id works.
    static func parseTMDBID(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed) { return n }
        guard let range = trimmed.range(of: #"(?:list|collection)/(\d+)"#, options: .regularExpression) else {
            // Fall back to the first run of digits anywhere in the string.
            let digits = trimmed.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        let match = String(trimmed[range])
        let digits = match.drop { !$0.isNumber }
        return Int(digits)
    }

    // MARK: - Collection source resolution

    /// Resolve a TMDB collection source into MetaItems. Each item's id is its
    /// IMDB tt id (resolved best-effort so it plays through Cinemeta); items
    /// whose IMDB id can't be resolved fall back to a `tmdb:<id>` id and still
    /// display. `language` comes from TMDB settings (ISO-639-1).
    /// `maxPages` caps how many TMDB discover pages are fetched. The collection
    /// BROWSE page wants the full catalog (default = unlimited), but Home rows
    /// only need ~one page of posters, so they pass maxPages: 1 to avoid firing
    /// hundreds of requests per folder on every Home load.
    /// `startPage` lets a caller fetch a WINDOW of pages (startPage ..<
    /// startPage+maxPages) instead of always starting at 1, so a big catalog
    /// can be streamed into the grid in chunks rather than assembled in full
    /// before anything appears. Only DISCOVER/COMPANY/NETWORK are paged; the
    /// other source types return their whole (small) result on the first call.
    static func resolve(source: CollectionSourceDTO, language: String, maxPages: Int = Int.max,
                        startPage: Int = 1) async -> [MetaItem] {
        guard source.provider.lowercased() == "tmdb",
              let sourceType = source.tmdbSourceType?.uppercased() else { return [] }
        let mediaIsMovie = (source.mediaType ?? "movie").lowercased() != "tv"
        let raw: [TMDBRawItem]
        do {
            switch sourceType {
            case "LIST":
                // Unpaged sources have already been returned in full by the
                // first window; later windows must not repeat them.
                raw = startPage > 1 ? [] : (try await resolveList(id: source.tmdbId, language: language))
            case "COLLECTION":
                raw = startPage > 1 ? [] : (try await resolveCollection(id: source.tmdbId, language: language))
            case "COMPANY", "NETWORK", "DISCOVER":
                raw = try await resolveDiscover(source: source, sourceType: sourceType, isMovie: mediaIsMovie, language: language, maxPages: maxPages, startPage: startPage)
            case "PERSON", "DIRECTOR":
                raw = startPage > 1 ? [] : (try await resolvePerson(id: source.tmdbId, director: sourceType == "DIRECTOR", isMovie: mediaIsMovie, language: language))
            default:
                raw = []
            }
        } catch {
            return []
        }
        return await mapToMetaItems(raw)
    }

    /// A TMDB entity flattened to the fields we need before IMDB resolution.
    /// `Sendable` so `mapToMetaItems` can hand items to `boundedConcurrentMap`.
    fileprivate struct TMDBRawItem: Sendable {
        let tmdbID: Int
        let isMovie: Bool
        let name: String
        let poster: String?
        let background: String?
        let description: String?
        let releaseInfo: String?
        let rating: Double?
        var genres: [String]? = nil
        /// TMDB's vote count, where the order needs it (Search's best-known
        /// titles).
        var votes: Int = 0
    }

    /// TMDB's genre id→name lists are small and effectively fixed — hardcoded
    /// here instead of an extra `/genre/movie|tv/list` round-trip per resolve.
    private static let movieGenres: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Science Fiction", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
    ]
    private static let tvGenres: [Int: String] = [
        10759: "Action & Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 10762: "Kids", 9648: "Mystery",
        10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap",
        10767: "Talk", 10768: "War & Politics", 37: "Western",
    ]

    /// Concurrency window for the `/external_ids` resolves in `mapToMetaItems`.
    /// Higher than the addon sweep limits on purpose: these are tiny JSON
    /// responses (and, after the first pass over a folder, mostly cache hits),
    /// so the peak-memory argument behind `AddonSweepLimits` barely applies.
    ///
    /// Widened because this sits IN FRONT OF FIRST PAINT: a 60-item collection
    /// page at a window of 12 is five sequential round-trip rounds before a
    /// single poster appears. These are tiny responses and mostly cache hits
    /// after the first pass, so the window is the only thing setting the wait.
    private static var imdbResolveWindow: Int { PerformanceProfile.isLowPower ? 12 : 24 }

    /// How many recommendations get an IMDb id resolved up front. The row is
    /// horizontally scrolling and this many comfortably fills it.
    private static let moreLikeThisResolveCap = 12

    private static func mapToMetaItems(_ raw: [TMDBRawItem]) async -> [MetaItem] {
        // Resolve EVERY item's IMDb id, not just `raw.prefix(40)`. The task
        // group resolved 40 but the mapping ran over the whole array, so item
        // 41 onward silently kept a `tmdb:` id — and a `tmdb:` id is a
        // different animal everywhere downstream (Trakt id mapping, addon
        // selection, Cinemeta meta lookups all key on `tt…`), so the tail of a
        // big company/network/genre folder behaved unlike its head.
        //
        // Bounded rather than unbounded: `boundedConcurrentMap` keeps at most
        // `imdbResolveWindow` requests in flight and returns results in input
        // order, so a 500-item folder resolves fully without firing 500
        // simultaneous URLSession requests at a 2 GB Apple TV. "" = unresolved
        // (a plain `String` avoids the double-optional the generic result would
        // otherwise carry).
        let resolvedIDs = await boundedConcurrentMap(raw, limit: imdbResolveWindow) { item in
            await imdbID(tmdbID: item.tmdbID, isMovie: item.isMovie) ?? ""
        }
        // Deduplicate on the FINAL id. Dedup upstream is by TMDB id, but the id
        // is then REWRITTEN to the resolved `tt…`, and two TMDB records can map
        // to one IMDb title (duplicate entries; a movie + tv pair in
        // `browseCompany`, which concatenates both discover calls). Two
        // MetaItems with the same id inside a SwiftUI `ForEach` take the tvOS
        // focus engine down, and several callers feed this straight into one —
        // so it has to happen here, where every caller is covered.
        var seenIDs = Set<String>()
        var mapped: [MetaItem] = []
        mapped.reserveCapacity(raw.count)
        for (index, item) in raw.enumerated() {
            let resolved = index < resolvedIDs.count ? resolvedIDs[index] : ""
            let id = resolved.isEmpty ? "tmdb:\(item.tmdbID)" : resolved
            guard seenIDs.insert(id).inserted else { continue }
            mapped.append(MetaItem(
                id: id,
                type: item.isMovie ? "movie" : "series",
                name: item.name,
                poster: item.poster,
                background: item.background,
                // (The logo as the add-ons' catalogs have it — by IMDb id.)
                logo: id.hasPrefix("tt") ? "https://images.metahub.space/logo/medium/\(id)/img" : nil,
                description: item.description,
                releaseInfo: item.releaseInfo,
                imdbRating: item.rating.map { String(format: "%.1f", $0) },
                genres: item.genres
            ))
        }
        return mapped
    }

    // MARK: - Endpoint helpers

    private static func resolveList(id: Int?, language: String) async throws -> [TMDBRawItem] {
        guard let id else { throw TMDBError.missing }
        struct ListResponse: Decodable { let items: [ListItem]? }
        struct ListItem: Decodable {
            let id: Int
            let title: String?; let name: String?
            let media_type: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?
        }
        let body: ListResponse = try await get("/list/\(id)", query: ["language": language])
        return (body.items ?? []).compactMap { item in
            let isMovie = (item.media_type?.lowercased() ?? "movie") != "tv"
            guard let title = item.title ?? item.name, !title.isEmpty else { return nil }
            return TMDBRawItem(
                tmdbID: item.id, isMovie: isMovie, name: title,
                poster: imageURL(item.poster_path, size: "w500") ?? imageURL(item.backdrop_path, size: "w780"),
                background: imageURL(item.backdrop_path, size: "original"),
                description: item.overview,
                releaseInfo: (item.release_date ?? item.first_air_date).map { String($0.prefix(4)) },
                rating: item.vote_average
            )
        }
    }

    private static func resolveCollection(id: Int?, language: String) async throws -> [TMDBRawItem] {
        guard let id else { throw TMDBError.missing }
        struct CollectionResponse: Decodable { let parts: [Part]? }
        struct Part: Decodable {
            let id: Int; let title: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let vote_average: Double?
        }
        let body: CollectionResponse = try await get("/collection/\(id)", query: ["language": language])
        // In release order (TMDB's isn't); parts with no date yet last.
        // Without any picture (a blank card): left out.
        let parts = (body.parts ?? []).sorted {
            ($0.release_date.flatMap { $0.isEmpty ? nil : $0 } ?? "9999") < ($1.release_date.flatMap { $0.isEmpty ? nil : $0 } ?? "9999")
        }
        return parts.compactMap { part in
            guard let title = part.title, !title.isEmpty else { return nil }
            guard part.poster_path != nil || part.backdrop_path != nil else { return nil }
            return TMDBRawItem(
                tmdbID: part.id, isMovie: true, name: title,
                poster: imageURL(part.poster_path, size: "w500") ?? imageURL(part.backdrop_path, size: "w780"),
                background: imageURL(part.backdrop_path, size: "original"),
                description: part.overview,
                releaseInfo: part.release_date.map { String($0.prefix(4)) },
                rating: part.vote_average
            )
        }
    }

    private static func resolveDiscover(source: CollectionSourceDTO, sourceType: String, isMovie: Bool, language: String, maxPages: Int = Int.max, startPage: Int = 1) async throws -> [TMDBRawItem] {
        let f = source.filters
        // NETWORK forces TV, because TMDB's with_networks filter is TV-only —
        // UNLESS a watch-provider override is present. Watch-provider data
        // works for movies too, so a network preset with one lets mediaType
        // drive movie vs TV instead of being stuck TV-only, which is why every
        // streaming-service category only ever showed shows, never movies.
        let hasWatchProviderOverride = f?.withWatchProviders?.isEmpty == false
        let useTV = (sourceType == "NETWORK" && !hasWatchProviderOverride) ? true : !isMovie
        var baseQuery: [String: String] = [
            "language": language,
            "sort_by": source.sortBy?.isEmpty == false ? source.sortBy! : "popularity.desc"
        ]
        if sourceType == "COMPANY" {
            // `filters.withCompanies` (pipe-separated, OR-match) overrides the
            // single tmdbId when set — some franchises are legally fragmented
            // across several TMDB company records (e.g. "DC Films" alone is
            // only ~17 titles; DC Films + DC Entertainment combined is the
            // real ~70-title DC catalog), so one company id badly undercounts
            // them. Plain single-studio collections (Pixar, A24, etc.) are
            // already complete under their one id and don't set this.
            if let multi = f?.withCompanies, !multi.isEmpty {
                baseQuery["with_companies"] = multi
            } else if let tid = source.tmdbId {
                baseQuery["with_companies"] = String(tid)
            }
        }
        if let v = f?.withGenres { baseQuery["with_genres"] = v }
        if let v = f?.withKeywords { baseQuery["with_keywords"] = v }
        if let v = f?.withOriginalLanguage { baseQuery["with_original_language"] = v }
        // Streaming-service filtering (Netflix, Hulu, Apple TV+, …): both keys
        // are required together by TMDB. Limit to subscription/flatrate offers.
        if let providers = f?.withWatchProviders, !providers.isEmpty {
            baseQuery["with_watch_providers"] = providers
            baseQuery["watch_region"] = (f?.watchRegion?.isEmpty == false) ? f!.watchRegion! : "US"
            baseQuery["with_watch_monetization_types"] = "flatrate"
        }
        if let v = f?.voteCountGte { baseQuery["vote_count.gte"] = String(v) }
        if let v = f?.voteAverageGte { baseQuery["vote_average.gte"] = String(v) }
        if let v = f?.year { baseQuery[useTV ? "first_air_date_year" : "year"] = String(v) }
        // "Newest Releases": a rolling window computed fresh THIS call (not a
        // fixed date, which would go stale), sorted by popularity instead of
        // release date. Verified live that plain sort_by=primary_release_date
        // surfaces unreleased 2029-2099 placeholder entries with zero votes —
        // not watchable "newest releases" at all.
        if let days = f?.recentDays, days > 0 {
            let today = Date()
            let past = Calendar.current.date(byAdding: .day, value: -days, to: today) ?? today
            let dateField = useTV ? "first_air_date" : "primary_release_date"
            baseQuery["\(dateField).lte"] = Self.isoDateOnly.string(from: today)
            baseQuery["\(dateField).gte"] = Self.isoDateOnly.string(from: past)
            baseQuery["sort_by"] = "popularity.desc"
        }
        if sourceType == "NETWORK", let tid = source.tmdbId, !hasWatchProviderOverride {
            baseQuery["with_networks"] = String(tid)
        }

        struct DiscoverResponse: Decodable { let results: [Result]?; let total_pages: Int? }
        struct Result: Decodable {
            let id: Int; let title: String?; let name: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?; let genre_ids: [Int]?
        }
        let path = useTV ? "/discover/tv" : "/discover/movie"
        let genreMap = useTV ? tvGenres : movieGenres
        // Retries a page on a 429 (brief backoff, a few attempts) since we now
        // routinely issue far more requests than before; any other failure
        // just skips that page rather than blocking the whole fetch.
        func fetchPage(_ page: Int) async -> DiscoverResponse? {
            var q = baseQuery
            q["page"] = String(page)
            for attempt in 0..<3 {
                do {
                    return try await get(path, query: q) as DiscoverResponse
                } catch TMDBError.badResponse(429) {
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
                } catch {
                    return nil
                }
            }
            return nil
        }

        // TMDB paginates discover results at 20/page and hard-caps the
        // endpoint itself at page 500 (10,000 results) — beyond that TMDB's
        // own API refuses the request, so 500 is TMDB's ceiling, not one we're
        // imposing. Fetch every page up to whichever is smaller so a category
        // shows its FULL TMDB catalog (this was previously capped much lower,
        // which is why large studios/networks looked incomplete). Batched in
        // chunks so a network with hundreds of pages doesn't fire them all
        // simultaneously — kinder to TMDB's rate limit and to the device.
        let tmdbPageCeiling = 500
        let batchSize = 20
        // Window: pages [startPage, startPage + maxPages).
        guard let first = await fetchPage(startPage) else { return [] }
        var allResults = first.results ?? []
        let available = min(first.total_pages ?? 1, tmdbPageCeiling)
        let totalPages = maxPages == Int.max ? available
            : min(available, startPage + max(1, maxPages) - 1)
        var page = startPage + 1
        while page <= totalPages {
            let upper = min(page + batchSize - 1, totalPages)
            await withTaskGroup(of: (Int, [Result]).self) { group in
                for p in page...upper {
                    group.addTask { (p, (await fetchPage(p))?.results ?? []) }
                }
                var byPage: [Int: [Result]] = [:]
                for await (p, results) in group { byPage[p] = results }
                for p in page...upper { allResults.append(contentsOf: byPage[p] ?? []) }
            }
            page = upper + 1
        }

        return allResults.compactMap { r in
            guard let title = r.title ?? r.name, !title.isEmpty else { return nil }
            let genres = r.genre_ids?.compactMap { genreMap[$0] }
            return TMDBRawItem(
                tmdbID: r.id, isMovie: !useTV, name: title,
                poster: imageURL(r.poster_path, size: "w500") ?? imageURL(r.backdrop_path, size: "w780"),
                background: imageURL(r.backdrop_path, size: "original"),
                description: r.overview,
                releaseInfo: (r.release_date ?? r.first_air_date).map { String($0.prefix(4)) },
                rating: r.vote_average,
                genres: (genres?.isEmpty == false) ? genres : nil
            )
        }
    }

    private static func resolvePerson(id: Int?, director: Bool, isMovie: Bool, language: String) async throws -> [TMDBRawItem] {
        guard let id else { throw TMDBError.missing }
        struct CreditsResponse: Decodable { let cast: [Credit]?; let crew: [Credit]? }
        struct Credit: Decodable {
            let id: Int; let title: String?; let name: String?
            let media_type: String?; let job: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?
        }
        let body: CreditsResponse = try await get("/person/\(id)/combined_credits", query: ["language": language])
        let credits = director
            ? (body.crew ?? []).filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
            : (body.cast ?? [])
        let wantTV = !isMovie
        return credits.compactMap { c in
            let credIsTV = (c.media_type?.lowercased() == "tv")
            guard credIsTV == wantTV else { return nil }
            guard let title = c.title ?? c.name, !title.isEmpty else { return nil }
            return TMDBRawItem(
                tmdbID: c.id, isMovie: !credIsTV, name: title,
                poster: imageURL(c.poster_path, size: "w500") ?? imageURL(c.backdrop_path, size: "w780"),
                background: imageURL(c.backdrop_path, size: "original"),
                description: c.overview,
                releaseInfo: (c.release_date ?? c.first_air_date).map { String($0.prefix(4)) },
                rating: c.vote_average
            )
        }
    }

    // MARK: - Detail enrichment (cast, more-like-this, collection)

    /// A cast member with a headshot, used on the Detail screen and clickable
    /// through to a Cast Detail filmography.
    struct CastMember: Identifiable, Hashable {
        let id: Int
        let name: String
        let character: String?
        let profileURL: String?
    }

    /// A movie collection ("belongs to") reference from TMDB.
    struct CollectionRef: Hashable {
        let id: Int
        let name: String
        let backdropURL: String?
    }

    /// A production company / network with a logo.
    struct Company: Identifiable, Hashable {
        let id: Int
        let name: String
        let logoURL: String
        /// A TV network (its id is a network's, not a company's).
        var isNetwork = false
    }

    /// Season and episode counts of a series, for compact meta lines.
    struct ShowSize: Hashable, Codable, Sendable {
        let seasons: Int
        let episodes: Int
    }

    /// Per-episode extras (rating, air date, better still) keyed by episode
    /// number, resolved from a TMDB season.
    struct EpisodeExtra: Hashable {
        let rating: Double?
        let airDate: String?
        let still: String?
        /// Episode length in minutes, when TMDB has it.
        var runtime: Int? = nil
    }

    /// A YouTube trailer/teaser. `youtubeKey` feeds the stream extractor.
    struct Trailer: Identifiable, Hashable {
        let id: String        // TMDB video id
        let name: String
        let youtubeKey: String
        var thumbnailURL: String { "https://img.youtube.com/vi/\(youtubeKey)/hqdefault.jpg" }
    }

    /// Everything the Detail screen pulls from TMDB in one call.
    struct Detail {
        var cast: [CastMember] = []
        var crew: [CastMember] = []      // director + writers, shown first in "Creator and Cast"
        var moreLikeThis: [MetaItem] = []
        var collection: CollectionRef?
        var companies: [Company] = []
        var trailers: [Trailer] = []
        var director: String?
        var country: String?             // primary production country name
        var language: String?            // spoken/original language, uppercased ISO (e.g. "EN")
        var releaseDate: String?         // ISO date for the localized full-date meta line
        var contentRating: String?        // US certification/rating, e.g. PG-13, R, TV-MA
        /// The title block's facts (creator line, status, runtime, …).
        var facts = TitleFacts()
        /// Details' About section: what the title block leaves out.
        var about = About()
    }

    /// Details' About section's facts beyond the title block's.
    struct About: Equatable {
        /// The title in its own language, when it differs.
        var originalTitle: String?
        /// Every production country.
        var countries: [String] = []
        /// Production companies (with or without a logo), and a show's networks.
        var studios: [String] = []
        var networks: [String] = []
        /// A film's, in US dollars (0 / unknown: nil).
        var budget: Int?
        var revenue: Int?
        /// A show's first and last air dates (ISO).
        var lastAirDate: String?
        /// TMDB's genres (with their ids: a genre's titles — see `titlesByGenre`).
        var genres: [Genre] = []
        /// TMDB's keywords ("based on novel", "time travel"), shown as tags.
        var keywords: [Keyword] = []
    }

    struct Keyword: Hashable, Sendable {
        let id: Int
        let name: String
    }

    struct Genre: Hashable, Sendable {
        let id: Int
        let name: String
    }

    /// What the title block (Detail overview and Home's billboard) shows
    /// beyond the catalog's own fields: "Creator: …", ENDED / ONGOING,
    /// certification, runtime, country, language.
    struct TitleFacts: Equatable, Codable, Sendable {
        var creatorLine: String?
        var contentRating: String?
        /// "ENDED" / "ONGOING" — series only.
        var status: String?
        /// A movie's runtime, or a series' episode runtime.
        var runtimeMinutes: Int?
        var country: String?
        var language: String?
        /// The one-line tagline ("Fear can hold you prisoner…"), if any.
        var tagline: String?

        /// Series: "Creator: …" (TMDB's creators, else writers, else
        /// directors). Movies: "Director: …" (else "Writer: …"). Two names
        /// at most.
        static func creatorLine(isMovie: Bool, creators: [String],
                                directors: [String], writers: [String]) -> String? {
            func line(_ names: [String], _ one: String, _ many: String) -> String? {
                let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                guard !unique.isEmpty else { return nil }
                return "\(unique.count > 1 ? many : one): \(unique.prefix(2).joined(separator: ", "))"
            }
            if isMovie {
                return line(directors, "Director", "Directors") ?? line(writers, "Writer", "Writers")
            }
            return line(creators, "Creator", "Creator") ?? line(writers, "Creator", "Creator")
                ?? line(directors, "Creator", "Creator")
        }

        /// TMDB's series status as the badge's word.
        static func status(_ raw: String?, isMovie: Bool) -> String? {
            guard !isMovie, let raw, !raw.isEmpty else { return nil }
            return ["Ended", "Canceled"].contains(raw) ? "ENDED" : "ONGOING"
        }
    }

    private static let factsLock = NSLock()
    private static var factsCache: [String: TitleFacts] = [:]

    private static func cachedFacts(_ key: String) -> TitleFacts? {
        factsLock.lock(); defer { factsLock.unlock() }
        return factsCache[key]
    }
    private static let factsDisk = DiskCache<TitleFacts>(name: "tmdb-facts")

    private static func storeFacts(_ facts: TitleFacts, for key: String) {
        factsLock.lock(); defer { factsLock.unlock() }
        factsCache[key] = facts
    }

    /// The facts if already loaded (no wait) — e.g. the tagline for a view
    /// drawn at once.
    static func knownFacts(for meta: MetaItem) -> TitleFacts? {
        cachedFacts("v2:\(meta.type):\(meta.id):\(preferredLanguage)")
    }

    /// The title block's facts on their own — for Home's billboard, which
    /// has no Detail page load behind it. One light request per title
    /// (credits + certification only), remembered for the session.
    static func facts(for meta: MetaItem) async -> TitleFacts? {
        // (v2: with the tagline — older stored facts lack it.)
        let key = "v2:\(meta.type):\(meta.id):\(preferredLanguage)"
        if let hit = cachedFacts(key) { return hit }
        // On disk for a day: a relaunch doesn't ask again.
        if let stored = await factsDisk.value(for: key, ttl: 24 * 60 * 60) {
            storeFacts(stored, for: key)
            return stored
        }
        guard hasAPIKey,
              let (tmdbID, isMovie) = await resolveTMDBID(from: meta.id, type: meta.type) else { return nil }
        struct Response: Decodable {
            struct Person: Decodable { let name: String }
            struct CrewDTO: Decodable { let name: String; let job: String? }
            struct Credits: Decodable { let crew: [CrewDTO]? }
            struct CountryDTO: Decodable { let name: String? }
            struct ReleaseDates: Decodable { let results: [ReleaseCountry]? }
            struct ReleaseCountry: Decodable { let iso_3166_1: String?; let release_dates: [ReleaseInfo]? }
            struct ReleaseInfo: Decodable { let certification: String? }
            struct ContentRatings: Decodable { let results: [TVRating]? }
            struct TVRating: Decodable { let iso_3166_1: String?; let rating: String? }
            let created_by: [Person]?
            let credits: Credits?
            let status: String?
            let runtime: Int?
            let episode_run_time: [Int]?
            let production_countries: [CountryDTO]?
            let original_language: String?
            let release_dates: ReleaseDates?
            let content_ratings: ContentRatings?
            let tagline: String?
        }
        let path = isMovie ? "/movie/\(tmdbID)" : "/tv/\(tmdbID)"
        guard let body: Response = try? await get(path, query: [
            "append_to_response": isMovie ? "credits,release_dates" : "credits,content_ratings"
        ]) else { return nil }
        let crew = body.credits?.crew ?? []
        var facts = TitleFacts()
        facts.creatorLine = TitleFacts.creatorLine(
            isMovie: isMovie,
            creators: (body.created_by ?? []).map(\.name),
            directors: crew.filter { $0.job == "Director" }.map(\.name),
            writers: crew.filter { ["Writer", "Screenplay"].contains($0.job ?? "") }.map(\.name))
        facts.status = TitleFacts.status(body.status, isMovie: isMovie)
        facts.runtimeMinutes = isMovie ? body.runtime : body.episode_run_time?.first
        facts.country = body.production_countries?.first?.name
        facts.language = body.original_language?.uppercased()
        let tagline = body.tagline?.trimmingCharacters(in: .whitespacesAndNewlines)
        facts.tagline = tagline?.isEmpty == false ? tagline : nil
        if isMovie {
            let countries = body.release_dates?.results ?? []
            let us = countries.first { $0.iso_3166_1 == "US" } ?? countries.first
            facts.contentRating = us?.release_dates?.compactMap {
                let c = $0.certification?.trimmingCharacters(in: .whitespaces)
                return c?.isEmpty == false ? c : nil
            }.first
        } else {
            let rows = body.content_ratings?.results ?? []
            let rating = (rows.first { $0.iso_3166_1 == "US" } ?? rows.first)?.rating?
                .trimmingCharacters(in: .whitespaces)
            facts.contentRating = rating?.isEmpty == false ? rating : nil
        }
        storeFacts(facts, for: key)
        await factsDisk.store(facts, for: key)
        return facts
    }

    // Cache imdb→(tmdbID,isMovie) resolutions from /find.
    private static var findCache: [String: (Int, Bool)] = [:]

    /// Resolve a MetaItem id to a TMDB id. Handles `tt…` (imdb, via /find),
    /// `tmdb:<n>`, and returns nil for id schemes TMDB can't map.
    static func resolveTMDBID(from id: String, type: String) async -> (id: Int, isMovie: Bool)? {
        let wantMovie = !(type == "series" || type == "tv")
        if id.hasPrefix("tmdb:") {
            guard let n = Int(id.dropFirst("tmdb:".count)) else { return nil }
            return (n, wantMovie)
        }
        guard id.hasPrefix("tt") else { return nil }
        if let hit = cachedFind(id) { return hit }
        struct FindResponse: Decodable {
            struct M: Decodable { let id: Int }
            let movie_results: [M]?
            let tv_results: [M]?
        }
        guard let body: FindResponse = try? await get("/find/\(id)", query: ["external_source": "imdb_id"]) else {
            // A FAILED request (`/find` is the most rate-limited endpoint and
            // the first hit of every Detail screen) is not "no match". Remember
            // which so callers don't cache a negative for a title TMDB does know.
            noteFindFailure(id)
            return nil
        }
        let result: (Int, Bool)?
        if wantMovie, let m = body.movie_results?.first { result = (m.id, true) }
        else if let t = body.tv_results?.first { result = (t.id, false) }
        else if let m = body.movie_results?.first { result = (m.id, true) }
        else { result = nil }
        if let result { storeFind(result, for: id) }
        clearFindFailure(id)
        return result
    }

    /// Ids whose most recent `/find` REQUEST failed (as opposed to answering
    /// "no match"). Callers that cache a negative on a nil resolve consult this
    /// so a 429 or a blip is retried next time instead of pinned for the session.
    private static var findFailures: Set<String> = []
    private static func noteFindFailure(_ id: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        findFailures.insert(id)
    }
    private static func clearFindFailure(_ id: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        findFailures.remove(id)
    }
    private static func lastFindFailed(_ id: String) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return findFailures.contains(id)
    }

    /// Pull cast (with headshots), recommendations/similar, and collection for
    /// a title in a single append_to_response call. Best-effort: returns nil on
    /// any failure so callers keep their Cinemeta fallbacks.
    static func detail(imdbID: String, type: String, language: String = preferredLanguage) async -> Detail? {
        guard let (tmdbID, isMovie) = await resolveTMDBID(from: imdbID, type: type) else { return nil }
        struct DetailResponse: Decodable {
            struct Credits: Decodable { let cast: [CastDTO]?; let crew: [CrewDTO]? }
            struct GenreDTO: Decodable { let id: Int; let name: String }
            let genres: [GenreDTO]?
            /// A film's under `keywords`, a show's under `results`.
            struct Keywords: Decodable { let keywords: [GenreDTO]?; let results: [GenreDTO]? }
            let keywords: Keywords?
            struct CastDTO: Decodable {
                let id: Int; let name: String; let character: String?; let profile_path: String?
            }
            struct CrewDTO: Decodable {
                let id: Int; let name: String; let job: String?; let profile_path: String?
            }
            struct RecoResponse: Decodable { let results: [RecoItem]? }
            struct RecoItem: Decodable {
                let id: Int; let title: String?; let name: String?; let media_type: String?
                let poster_path: String?; let backdrop_path: String?
                let overview: String?; let release_date: String?; let first_air_date: String?
                let vote_average: Double?
            }
            struct BelongsTo: Decodable { let id: Int; let name: String; let backdrop_path: String? }
            struct CompanyDTO: Decodable { let id: Int; let name: String; let logo_path: String? }
            struct CountryDTO: Decodable { let iso_3166_1: String?; let name: String? }
            struct Videos: Decodable { let results: [VideoDTO]? }
            struct VideoDTO: Decodable {
                let id: String; let key: String; let name: String
                let site: String?; let type: String?; let official: Bool?
            }
            struct ReleaseDates: Decodable { let results: [ReleaseCountry]? }
            struct ReleaseCountry: Decodable { let iso_3166_1: String?; let release_dates: [ReleaseInfo]? }
            struct ReleaseInfo: Decodable { let certification: String?; let type: Int? }
            struct ContentRatings: Decodable { let results: [TVRating]? }
            struct TVRating: Decodable { let iso_3166_1: String?; let rating: String? }
            let credits: Credits?
            let recommendations: RecoResponse?
            let similar: RecoResponse?
            let belongs_to_collection: BelongsTo?
            let production_companies: [CompanyDTO]?
            let production_countries: [CountryDTO]?
            let original_language: String?
            let release_date: String?
            let first_air_date: String?
            let last_air_date: String?
            let original_title: String?
            let original_name: String?
            let budget: Int?
            let revenue: Int?
            let networks: [CompanyDTO]?
            let videos: Videos?
            let release_dates: ReleaseDates?
            let content_ratings: ContentRatings?
            struct Person: Decodable { let id: Int?; let name: String; let profile_path: String? }
            let created_by: [Person]?
            /// A show's cast across all its seasons (with episode counts).
            struct Aggregate: Decodable { let cast: [AggregateCast]? }
            struct AggregateCast: Decodable {
                let id: Int; let name: String; let profile_path: String?
                let roles: [Role]?; let total_episode_count: Int?
                struct Role: Decodable { let character: String?; let episode_count: Int? }
            }
            let aggregate_credits: Aggregate?
            let status: String?
            let runtime: Int?
            let episode_run_time: [Int]?
        }
        let path = isMovie ? "/movie/\(tmdbID)" : "/tv/\(tmdbID)"
        let appended = isMovie
            ? "credits,recommendations,similar,videos,release_dates,keywords"
            : "credits,aggregate_credits,recommendations,similar,videos,content_ratings,keywords"
        // From disk when it can be (stale-while-revalidate): fresh 3 days,
        // 7 for an ended show; kept 30 (docs/LOADING-PLAN.md §2).
        guard let body: DetailResponse = try? await cachedGet(
            path, query: ["language": language, "append_to_response": appended],
            fresh: { ["Ended", "Canceled"].contains($0.status ?? "") ? 7 * day : 3 * day },
            keep: 30 * day
        ) else { return nil }

        func movieCertification(_ dates: DetailResponse.ReleaseDates?) -> String? {
            let countries = dates?.results ?? []
            let preferred = countries.first { $0.iso_3166_1 == "US" } ?? countries.first
            let releases = preferred?.release_dates ?? []
            let rankedTypes = [3, 2, 4, 5, 1, 6]
            for type in rankedTypes {
                if let cert = releases.first(where: { $0.type == type })?.certification,
                   !cert.trimmingCharacters(in: .whitespaces).isEmpty {
                    return cert
                }
            }
            return releases.compactMap { cert in
                let value = cert.certification?.trimmingCharacters(in: .whitespaces)
                return value?.isEmpty == false ? value : nil
            }.first
        }

        func tvContentRating(_ ratings: DetailResponse.ContentRatings?) -> String? {
            let rows = ratings?.results ?? []
            let preferred = rows.first { $0.iso_3166_1 == "US" } ?? rows.first
            let rating = preferred?.rating?.trimmingCharacters(in: .whitespaces)
            return rating?.isEmpty == false ? rating : nil
        }

        var detail = Detail()
        // Portraits (2:3) at a size for Details' cards on a 4K screen.
        let portrait = "h632"
        // A show: everyone across its seasons, most episodes first (the
        // main cast who left early too); its role with the most episodes.
        // A film: the billing order.
        var castMembers: [CastMember]
        if !isMovie, let aggregate = body.aggregate_credits?.cast, !aggregate.isEmpty {
            castMembers = aggregate
                .sorted { ($0.total_episode_count ?? 0) > ($1.total_episode_count ?? 0) }
                .prefix(24).map { member in
                    let role = member.roles?.max { ($0.episode_count ?? 0) < ($1.episode_count ?? 0) }
                    return CastMember(id: member.id, name: member.name, character: role?.character,
                                      profileURL: imageURL(member.profile_path, size: portrait))
                }
        } else {
            castMembers = (body.credits?.cast ?? []).prefix(24).map {
                CastMember(id: $0.id, name: $0.name, character: $0.character,
                           profileURL: imageURL($0.profile_path, size: portrait))
            }
        }
        // Director + writers first (shown ahead of the cast in "Creator and
        // Cast"), ONE ENTRY PER PERSON.
        //
        // TMDB lists a writer-director once per job, and a crew member can also
        // be billed in the cast — so the row that renders `crew + cast` used to
        // get duplicate identifiers for any auteur title (Nolan, the Coens, an
        // actor-director like Eastwood), which is undefined behaviour in a
        // SwiftUI ForEach. Merge each person's jobs into one label, fold in
        // their acting credit, and take four PEOPLE rather than four credits.
        let crew = body.credits?.crew ?? []
        let importantJobs = ["Director", "Writer", "Screenplay", "Creator"]
        var crewOrder: [Int] = []
        var crewJobs: [Int: [String]] = [:]
        var crewInfo: [Int: (name: String, profile: String?)] = [:]
        // A show's creators first (TMDB lists them apart from the crew).
        for creator in body.created_by ?? [] {
            guard let id = creator.id, crewJobs[id] == nil else { continue }
            crewOrder.append(id)
            crewJobs[id] = ["Creator"]
            crewInfo[id] = (creator.name, imageURL(creator.profile_path, size: portrait))
        }
        for member in crew where importantJobs.contains(member.job ?? "") {
            let job = member.job ?? ""
            if crewJobs[member.id] == nil {
                crewOrder.append(member.id)
                crewJobs[member.id] = [job]
                crewInfo[member.id] = (member.name, imageURL(member.profile_path, size: portrait))
            } else if !(crewJobs[member.id]?.contains(job) ?? true) {
                crewJobs[member.id]?.append(job)
            }
        }
        detail.crew = crewOrder.prefix(4).compactMap { id -> CastMember? in
            guard let info = crewInfo[id], let jobs = crewJobs[id] else { return nil }
            var label = jobs.joined(separator: ", ")
            // Also in the cast: keep the character here so nothing is lost when
            // the duplicate entry is dropped below.
            if let character = castMembers.first(where: { $0.id == id })?.character,
               !character.isEmpty {
                label += " · \(character)"
            }
            return CastMember(id: id, name: info.name, character: label, profileURL: info.profile)
        }
        let crewIDs = Set(detail.crew.map(\.id))
        castMembers.removeAll { crewIDs.contains($0.id) }
        // TMDB also lists one person twice within `cast` itself (dual roles, and
        // "Self" / "Self - archive footage" in documentaries). Deduplicating
        // crew against cast is not enough on its own: the row that renders
        // `crew + cast` would still get a repeated identifier.
        var seenCast = Set<Int>()
        detail.cast = castMembers.filter { seenCast.insert($0.id).inserted }
        detail.director = crew.first { $0.job == "Director" }?.name
            ?? crew.first { $0.job == "Creator" }?.name
        detail.country = body.production_countries?.first?.name
        detail.language = body.original_language?.uppercased()
        detail.releaseDate = body.release_date ?? body.first_air_date
        detail.contentRating = isMovie
            ? movieCertification(body.release_dates)
            : tvContentRating(body.content_ratings)
        detail.facts = TitleFacts(
            creatorLine: TitleFacts.creatorLine(
                isMovie: isMovie,
                creators: (body.created_by ?? []).map(\.name),
                directors: crew.filter { $0.job == "Director" }.map(\.name),
                writers: crew.filter { ["Writer", "Screenplay"].contains($0.job ?? "") }.map(\.name)),
            contentRating: detail.contentRating,
            status: TitleFacts.status(body.status, isMovie: isMovie),
            runtimeMinutes: isMovie ? body.runtime : body.episode_run_time?.first,
            country: detail.country,
            language: detail.language)
        let recoResults = (body.recommendations?.results?.isEmpty == false)
            ? body.recommendations?.results
            : body.similar?.results
        // (Not yet out, or without any picture — a blank card: left out,
        // before the cap, so the row still fills.)
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let raw = (recoResults ?? []).compactMap { r -> TMDBRawItem? in
            let itemIsTV = (r.media_type?.lowercased() == "tv") || (!isMovie && r.media_type == nil)
            guard let title = r.title ?? r.name, !title.isEmpty else { return nil }
            guard r.poster_path != nil || r.backdrop_path != nil else { return nil }
            guard let released = r.release_date ?? r.first_air_date, !released.isEmpty, released <= today
            else { return nil }
            return TMDBRawItem(
                tmdbID: r.id, isMovie: !itemIsTV, name: title,
                poster: imageURL(r.poster_path, size: "w500") ?? imageURL(r.backdrop_path, size: "w780"),
                background: imageURL(r.backdrop_path, size: "original"),
                description: r.overview,
                releaseInfo: (r.release_date ?? r.first_air_date).map { String($0.prefix(4)) },
                rating: r.vote_average
            )
        }
        // Only the items the row actually shows. This resolve sits INSIDE
        // `detail()`, so every id looked up here delayed the publication of the
        // cast, crew, director, trailers and content rating — holding the top of
        // the title page hostage to a row further down that most viewers never
        // scroll to. Anything past the cap keeps its `tmdb:` id, which opens
        // correctly: `DetailViewModel.load` canonicalises on open.
        detail.moreLikeThis = await mapToMetaItems(Array(raw.prefix(moreLikeThisResolveCap)))
        if let bt = body.belongs_to_collection {
            detail.collection = CollectionRef(id: bt.id, name: bt.name,
                                              backdropURL: imageURL(bt.backdrop_path, size: "w780"))
        }
        let originalTitle = isMovie ? body.original_title : body.original_name
        detail.about = About(
            originalTitle: originalTitle,
            countries: (body.production_countries ?? []).compactMap(\.name),
            studios: (body.production_companies ?? []).map(\.name),
            networks: (body.networks ?? []).map(\.name),
            budget: body.budget.flatMap { $0 > 0 ? $0 : nil },
            revenue: body.revenue.flatMap { $0 > 0 ? $0 : nil },
            lastAirDate: isMovie ? nil : body.last_air_date,
            genres: (body.genres ?? []).map { Genre(id: $0.id, name: $0.name) },
            keywords: (body.keywords?.keywords ?? body.keywords?.results ?? []).map { Keyword(id: $0.id, name: $0.name) })
        // A show's networks first (where it airs), then the studios.
        let networks = (body.networks ?? []).compactMap { n -> Company? in
            guard let logo = imageURL(n.logo_path, size: "w300") else { return nil }
            return Company(id: n.id, name: n.name, logoURL: logo, isNetwork: true)
        }
        detail.companies = networks + (body.production_companies ?? []).compactMap { c in
            guard let logo = imageURL(c.logo_path, size: "w300") else { return nil }
            return Company(id: c.id, name: c.name, logoURL: logo)
        }
        // YouTube trailers/teasers, official first, "Trailer" before "Teaser".
        let videos = (body.videos?.results ?? []).filter {
            ($0.site?.caseInsensitiveCompare("YouTube") == .orderedSame)
                && ["Trailer", "Teaser"].contains($0.type ?? "")
        }
        detail.trailers = videos
            .sorted { a, b in
                if (a.official ?? false) != (b.official ?? false) { return (a.official ?? false) }
                return (a.type == "Trailer" ? 0 : 1) < (b.type == "Trailer" ? 0 : 1)
            }
            .map { Trailer(id: $0.id, name: $0.name, youtubeKey: $0.key) }
        return detail
    }

    static func contentRating(imdbID: String, type: String) async -> String? {
        let cacheKey = "\(type):\(imdbID)"
        if let cached = cachedContentRating(cacheKey) {
            return cached.isEmpty ? nil : cached
        }
        guard let (tmdbID, isMovie) = await resolveTMDBID(from: imdbID, type: type) else {
            if !lastFindFailed(imdbID) { storeContentRating(nil, for: cacheKey) }
            return nil
        }

        let rating: String?
        if isMovie {
            struct ReleaseDates: Decodable { let results: [ReleaseCountry]? }
            struct ReleaseCountry: Decodable { let iso_3166_1: String?; let release_dates: [ReleaseInfo]? }
            struct ReleaseInfo: Decodable { let certification: String?; let type: Int? }
            // A failed REQUEST is not a negative answer: caching it hid the
            // rating for the rest of the session after one 429 or blip.
            guard let body: ReleaseDates = try? await get("/movie/\(tmdbID)/release_dates") else {
                return nil
            }
            let countries = body.results ?? []
            let releases = (countries.first { $0.iso_3166_1 == "US" } ?? countries.first)?.release_dates ?? []
            rating = [3, 2, 4, 5, 1, 6].compactMap { releaseType in
                releases.first(where: { $0.type == releaseType })?.certification?.trimmingCharacters(in: .whitespaces)
            }.first { !$0.isEmpty }
                ?? releases.compactMap { $0.certification?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        } else {
            struct ContentRatings: Decodable { let results: [TVRating]? }
            struct TVRating: Decodable { let iso_3166_1: String?; let rating: String? }
            guard let body: ContentRatings = try? await get("/tv/\(tmdbID)/content_ratings") else {
                return nil
            }
            let rows = body.results ?? []
            let value = (rows.first { $0.iso_3166_1 == "US" } ?? rows.first)?.rating?.trimmingCharacters(in: .whitespaces)
            rating = value?.isEmpty == false ? value : nil
        }
        storeContentRating(rating, for: cacheKey)
        return rating
    }

    /// Per-episode extras for a season, keyed by episode number. Used to show
    /// ratings + air dates on the Detail episode row. Best-effort.
    static func seasonEpisodes(imdbID: String, type: String, season: Int) async -> [Int: EpisodeExtra] {
        let cacheKey = "\(type):\(imdbID):s\(season)"
        if let cached = cachedSeasonEpisodes(cacheKey) { return cached }
        guard let (tmdbID, _) = await resolveTMDBID(from: imdbID, type: type) else {
            if !lastFindFailed(imdbID) { storeSeasonEpisodes([:], for: cacheKey) }
            return [:]
        }
        struct SeasonResponse: Decodable {
            struct Episode: Decodable {
                let episode_number: Int?
                let vote_average: Double?
                let air_date: String?
                let still_path: String?
                let runtime: Int?
            }
            let episodes: [Episode]?
        }
        // From disk when it can be: a season whose episodes all aired more
        // than two weeks ago doesn't change (fresh 30 days); the current one
        // 12 h. Kept 60 days.
        guard let body: SeasonResponse = try? await cachedGet(
            "/tv/\(tmdbID)/season/\(season)",
            fresh: { body in
                let cutoff = Date().addingTimeInterval(-14 * day)
                let dates = (body.episodes ?? []).map { $0.air_date.flatMap(ReleaseDateParser.parse) }
                let settled = !dates.isEmpty && dates.allSatisfy { ($0 ?? .distantFuture) < cutoff }
                return settled ? 30 * day : 12 * 60 * 60
            },
            keep: 60 * day
        ) else {
            return [:]   // transient failure — not cached, retried next time
        }
        var map: [Int: EpisodeExtra] = [:]
        for ep in body.episodes ?? [] {
            guard let n = ep.episode_number else { continue }
            map[n] = EpisodeExtra(
                rating: (ep.vote_average ?? 0) > 0 ? ep.vote_average : nil,
                airDate: ep.air_date,
                still: imageURL(ep.still_path, size: "w300"),
                runtime: ep.runtime
            )
        }
        storeSeasonEpisodes(map, for: cacheKey)
        return map
    }

    /// The YouTube trailer keys for a title — the hero's billboard preview.
    ///
    /// The dedicated /videos endpoint rather than `detail`: a hero rest
    /// shouldn't pay for credits, recommendations and release dates it will
    /// never show. Same ranking as `detail` — YouTube only, Trailer/Teaser
    /// only, official first, Trailer before Teaser.
    ///
    /// The whole ranked list is kept, not just the winner: an empty array is a
    /// cached MISS, a missing entry means "not looked up yet". Misses are
    /// cached because browsing wanders across the same handful of titles all
    /// evening, and a title with no trailer would otherwise re-ask on every
    /// visit.
    /// Guarded by `cacheLock`, like every other cache in this file — this one
    /// was the exception. `trailerKeys` is a nonisolated async static, so
    /// the hero-trailer layer calls it OFF the main actor, and stepping across
    /// a poster row starts the next lookup without awaiting the previous one:
    /// two concurrent tasks mutating a plain Dictionary is a corrupted hash
    /// table or EXC_BAD_ACCESS, exactly what the note at the top of this file
    /// warns about.
    private static var trailerKeyCache: [String: [String]] = [:]

    private static func cachedTrailerKeys(_ key: String) -> [String]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return trailerKeyCache[key]
    }

    private static func storeTrailerKeys(_ value: [String], for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        // Capped like the id maps: this was the one cache in the file that never
        // evicted, so a long browse accumulated an entry per title viewed.
        capped(&trailerKeyCache, limit: idCacheLimit)
        trailerKeyCache[key] = value
    }

    /// Every YouTube trailer/teaser TMDB lists for a title, best first.
    ///
    /// The callers used to take the top-ranked key and stop there, which made
    /// one geo-restricted video enough to leave a title with no preview at
    /// all — the everyday case when the box leaves the house through a VPN
    /// exit in another country, since YouTube restricts trailers by region
    /// like any other upload. TMDB usually lists several, and the ones behind
    /// the first are often not restricted at all.
    ///
    /// A show's `season` (the one the billboard or Details is about): that
    /// season's trailers first — "Thousand-Year Blood War", not Bleach's 2004
    /// one — then the show's. With `aired` (an episode of it), TMDB's season
    /// is the one airing then: the add-ons number seasons their own way
    /// (Bleach's TYBW is the add-on's 17, TMDB's 2).
    static func trailerKeys(id: String, type: String, season: Int? = nil, aired: Date? = nil) async -> [String] {
        let cacheKey = "\(type):\(id)" + (season.map { "#\($0)" } ?? "")
        if let hit = cachedTrailerKeys(cacheKey) { return hit }
        guard let (tmdbID, isMovie) = await resolveTMDBID(from: id, type: type) else {
            // A failed `/find` is not a miss: caching [] here branded the title
            // trailer-less for the whole session on one transient error — the
            // rule the sibling caches (contentRating/seasonEpisodes/episodeCast)
            // already follow via `lastFindFailed`.
            if !lastFindFailed(id) { storeTrailerKeys([], for: cacheKey) }
            return []
        }
        struct VideosResponse: Decodable {
            struct Video: Decodable {
                let key: String?
                let site: String?
                let type: String?
                let official: Bool?
                let name: String?
                let size: Int?
                let iso_639_1: String?
                let published_at: String?
            }
            let results: [Video]?
        }
        let show = isMovie ? "/movie/\(tmdbID)/videos" : "/tv/\(tmdbID)/videos"
        var tmdbSeason = season
        if !isMovie, season != nil {
            struct Seasons: Decodable {
                struct Season: Decodable { let season_number: Int?; let air_date: String? }
                let seasons: [Season]?
            }
            let day: TimeInterval = 24 * 60 * 60
            let list: Seasons? = try? await cachedGet("/tv/\(tmdbID)", fresh: { _ in day }, keep: 30 * day)
            let seasons = (list?.seasons ?? []).filter { ($0.season_number ?? 0) > 0 }
            if let aired {
                // The last season to start by then (a day's slack for time zones).
                tmdbSeason = seasons
                    .compactMap { s in s.air_date.flatMap(ReleaseDateParser.parse).map { (s.season_number!, $0) } }
                    .filter { $0.1 <= aired.addingTimeInterval(day) }
                    .max { $0.1 < $1.1 }?.0
            } else if !seasons.contains(where: { $0.season_number == season }) {
                tmdbSeason = nil
            }
        }
        let paths = tmdbSeason.map { ["/tv/\(tmdbID)/season/\($0)/videos", show] } ?? [show]
        // A `language` alone returns only that language's videos — often none
        // outside English; ask for it, English and the untagged ones.
        let language = String(preferredLanguage.prefix(2)).lowercased()
        let wanted = language == "en" ? "en,null" : "\(language),en,null"
        var bodies: [VideosResponse?] = []
        for path in paths {
            // On disk for a day (refreshed behind): the billboard's titles
            // are asked at every launch.
            let day: TimeInterval = 24 * 60 * 60
            bodies.append(try? await cachedGet(path, query: [
                "language": preferredLanguage, "include_video_language": wanted,
            ], fresh: { (_: VideosResponse) in day }, keep: 30 * day))
        }
        // Best first: a real trailer (not a recap or a clip under the
        // Trailer label), in the user's language, then English; a Trailer
        // over a Teaser; official; "Official / Main / Final Trailer" named;
        // the larger upload; the newest (the final cut, a cleaner file).
        let junk = /\b(recap|clips?|scenes?|featurettes?|behind the scenes|reactions?|fan[ -]?made|tv spots?|spots?|reviews?|explained|breakdown)\b/
        let lead = /\b(official|main|final) trailer\b/
        func rank(_ v: VideosResponse.Video) -> [Int] {
            let name = (v.name ?? "").lowercased()
            let tongue = (v.iso_639_1 ?? "").lowercased()
            return [
                name.contains(junk) ? 1 : 0,
                tongue == language ? 0 : tongue == "en" ? 1 : 2,
                v.type == "Trailer" ? 0 : 1,
                (v.official ?? false) ? 0 : 1,
                name.contains(lead) ? 0 : 1,
                -(v.size ?? 0),
            ]
        }
        func ranked(_ body: VideosResponse?) -> [String] {
            (body?.results ?? [])
            .filter {
                ($0.site?.caseInsensitiveCompare("YouTube") == .orderedSame)
                    && ["Trailer", "Teaser"].contains($0.type ?? "")
            }
            .map { (video: $0, rank: rank($0)) }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank.lexicographicallyPrecedes(b.rank) }
                return (a.video.published_at ?? "") > (b.video.published_at ?? "")
            }
            .compactMap { $0.video.key }
        }
        var keys: [String] = []
        for key in bodies.flatMap(ranked) where !keys.contains(key) { keys.append(key) }
        // A failed REQUEST is not a miss — leave it uncached so a flaky
        // network doesn't brand the title trailer-less for the session.
        if !bodies.contains(where: { $0 == nil }) { storeTrailerKeys(keys, for: cacheKey) }
        return keys
    }

    /// The whole episode list for a series, as `MetaVideo`s the detail page
    /// can render directly.
    ///
    /// The LAST RESORT behind the meta add-ons: a catalog-only add-on can hand
    /// out series whose ids no installed meta provider really serves, and the
    /// detail page then had a title, a backdrop, and no way to pick an episode.
    /// TMDB knows the season/episode structure of essentially every series, so
    /// when every add-on comes back without a `videos` array this fills it in.
    ///
    /// Episode ids follow Stremio's `<series id>:<season>:<episode>` shape, so
    /// everything downstream — progress keys, watched state, the stream search
    /// — behaves exactly as it does for a Cinemeta series.
    static func episodes(for seriesID: String, type: String,
                         language: String = preferredLanguage) async -> [MetaVideo] {
        guard let (tmdbID, isMovie) = await resolveTMDBID(from: seriesID, type: type), !isMovie else {
            return []
        }
        struct ShowResponse: Decodable {
            struct SeasonRef: Decodable {
                let season_number: Int?
                let episode_count: Int?
            }
            let seasons: [SeasonRef]?
        }
        guard let show: ShowResponse = try? await get("/tv/\(tmdbID)", query: ["language": language]) else {
            return []
        }
        // Specials (season 0) included — `MetaItem.playbackSeasons` already
        // knows to prefer the numbered seasons and only fall back to 0.
        let numbers = (show.seasons ?? [])
            .compactMap(\.season_number)
            .filter { $0 >= 0 && ($0 > 0 || (show.seasons?.first { $0.season_number == 0 }?.episode_count ?? 0) > 0) }
            .sorted()
        guard !numbers.isEmpty else { return [] }

        struct SeasonResponse: Decodable {
            struct Episode: Decodable {
                let episode_number: Int?
                let name: String?
                let overview: String?
                let air_date: String?
                let still_path: String?
            }
            let episodes: [Episode]?
        }
        var out: [MetaVideo] = []
        // Serial, not concurrent: a long-running show is 20+ season requests
        // and TMDB rate-limits per IP. Capped for the same reason — nobody is
        // scrolling past fifty seasons, and this only ever runs as a fallback.
        for season in numbers.prefix(50) {
            guard let body: SeasonResponse = try? await get(
                "/tv/\(tmdbID)/season/\(season)", query: ["language": language]
            ) else { continue }
            for episode in body.episodes ?? [] {
                guard let number = episode.episode_number else { continue }
                out.append(MetaVideo(
                    id: "\(seriesID):\(season):\(number)",
                    title: episode.name,
                    season: season,
                    episode: number,
                    thumbnail: imageURL(episode.still_path, size: "w300"),
                    overview: episode.overview,
                    released: episode.air_date
                ))
            }
        }
        return out
    }

    static func episodeCast(imdbID: String, type: String, episode: MetaVideo) async -> [CastMember] {
        guard let season = episode.originalSeason ?? episode.season,
              let number = episode.originalEpisode ?? episode.episode else { return [] }
        let cacheKey = "\(type):\(imdbID):s\(season):e\(number)"
        if let cached = cachedEpisodeCast(cacheKey) { return cached }
        guard let (tmdbID, isMovie) = await resolveTMDBID(from: imdbID, type: type), !isMovie else {
            if !lastFindFailed(imdbID) { storeEpisodeCast([], for: cacheKey) }
            return []
        }
        struct CreditsResponse: Decodable {
            struct CastDTO: Decodable {
                let id: Int
                let name: String
                let character: String?
                let profile_path: String?
            }
            let cast: [CastDTO]?
        }
        guard let body: CreditsResponse = try? await get(
            "/tv/\(tmdbID)/season/\(season)/episode/\(number)/credits"
        ) else {
            return []   // transient failure — not cached, retried next time
        }
        let cast = (body.cast ?? []).prefix(12).map {
            CastMember(
                id: $0.id,
                name: $0.name,
                character: $0.character,
                profileURL: imageURL($0.profile_path, size: "w300")
            )
        }
        storeEpisodeCast(cast, for: cacheKey)
        return cast
    }

    /// The parts of a TMDB collection as MetaItems (for the "belongs to" row).
    static func collectionItems(id: Int, language: String = preferredLanguage) async -> [MetaItem] {
        guard let raw = try? await resolveCollection(id: id, language: language) else { return [] }
        return await mapToMetaItems(raw)
    }

    /// Whether a genre NAME is known for movies / TV (so callers can decide which
    /// media type(s) to query for a Categories genre).
    static func hasMovieGenre(_ name: String) -> Bool { movieGenres.values.contains(name) }
    /// A genre by its name, as TMDB has it for films / shows (nil: none).
    static func genre(named name: String, isMovie: Bool) -> Genre? {
        (isMovie ? movieGenres : tvGenres).first { $0.value == name }.map { Genre(id: $0.key, name: $0.value) }
    }
    static func hasTVGenre(_ name: String) -> Bool { tvGenres.values.contains(name) }

    // MARK: Browse pages (genre, tag, studio, network, person)

    /// How a browse page orders its titles.
    enum BrowseSort: String, CaseIterable, Sendable {
        case popular, topRated, newest, alphabetical

        var label: String {
            switch self {
            case .popular: return "Popular"
            case .topRated: return "Top rated"
            case .newest: return "Newest"
            case .alphabetical: return "A–Z"
            }
        }
    }

    /// One page of a browse list (twenty titles): the total TMDB knows of,
    /// and whether more follow.
    struct BrowsePage: Sendable {
        let items: [MetaItem]
        let total: Int
        let hasMore: Bool
    }

    private static let browsePageSize = 20

    /// A page of titles by a discover filter (`with_genres`, `with_keywords`,
    /// `with_companies`, `with_networks`), movies or shows, in `sort`'s order.
    static func browse(filter: [String: String], isMovie: Bool, sort: BrowseSort, page: Int,
                       language: String = preferredLanguage) async -> BrowsePage {
        var query = filter
        let today = Date().formatted(.iso8601.year().month().day())
        let dateKey = isMovie ? "primary_release_date" : "first_air_date"
        switch sort {
        case .popular:
            query["sort_by"] = "popularity.desc"
        case .topRated:
            // (A few votes on a hidden gem is no ranking.)
            query["sort_by"] = "vote_average.desc"
            query["vote_count.gte"] = "200"
        case .newest:
            query["sort_by"] = "\(dateKey).desc"
            query["\(dateKey).lte"] = today
            query["vote_count.gte"] = "10"
        case .alphabetical:
            // (Else it opens on "!", "#" and digits: tiny unknown entries.)
            query["sort_by"] = isMovie ? "title.asc" : "name.asc"
            query["vote_count.gte"] = "50"
        }
        query["page"] = String(page)
        let result = await discoverPage(path: isMovie ? "/discover/movie" : "/discover/tv", with: query,
                                        isMovie: isMovie, language: language)
        let shown = result.items.filter { $0.poster != nil }
        return BrowsePage(items: await mapToMetaItems(shown), total: result.total,
                          hasMore: page < min(result.pages, 500))
    }

    private static func discoverPage(path: String, with extra: [String: String], isMovie: Bool,
                                     language: String) async -> (items: [TMDBRawItem], total: Int, pages: Int) {
        var query = ["language": language, "page": "1", "sort_by": "popularity.desc"]
        extra.forEach { query[$0.key] = $0.value }
        struct DiscoverResponse: Decodable {
            let results: [Result]?
            let total_results: Int?
            let total_pages: Int?
        }
        struct Result: Decodable {
            let id: Int; let title: String?; let name: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?; let vote_count: Int?
        }
        guard let body: DiscoverResponse = try? await get(path, query: query) else { return ([], 0, 0) }
        let items: [TMDBRawItem] = (body.results ?? []).compactMap { r in
            guard let title = r.title ?? r.name, !title.isEmpty else { return nil }
            return TMDBRawItem(
                tmdbID: r.id, isMovie: isMovie, name: title,
                poster: imageURL(r.poster_path, size: "w500") ?? imageURL(r.backdrop_path, size: "w780"),
                background: imageURL(r.backdrop_path, size: "original"),
                description: r.overview,
                releaseInfo: (r.release_date ?? r.first_air_date).map { String($0.prefix(4)) },
                rating: r.vote_average,
                votes: r.vote_count ?? 0
            )
        }
        return (items, body.total_results ?? items.count, body.total_pages ?? 1)
    }

    /// A studio's best-known titles, films and shows together, by their
    /// votes (lasting fame) — Search's Top Results after the studio.
    static func studioBestKnown(id: Int, limit: Int) async -> [MetaItem] {
        let filter = ["with_companies": String(id), "sort_by": "vote_count.desc"]
        async let movies = discoverPage(path: "/discover/movie", with: filter, isMovie: true,
                                        language: preferredLanguage)
        async let shows = discoverPage(path: "/discover/tv", with: filter, isMovie: false,
                                       language: preferredLanguage)
        let all = await (movies.items + shows.items).filter { $0.poster != nil }.sorted { $0.votes > $1.votes }
        // (A few more than asked for: some have no IMDb id.)
        return Array(await mapToMetaItems(Array(all.prefix(limit * 2))).filter { $0.id.hasPrefix("tt") }.prefix(limit))
    }

    /// A studio's or network's page header: its logo and where it is from.
    struct BrandProfile: Sendable {
        let logoURL: String?
        let country: String?
    }

    static func brandProfile(id: Int, isNetwork: Bool) async -> BrandProfile? {
        struct Response: Decodable { let logo_path: String?; let origin_country: String? }
        guard let body: Response = try? await get(isNetwork ? "/network/\(id)" : "/company/\(id)") else { return nil }
        return BrandProfile(logoURL: imageURL(body.logo_path, size: "w500"),
                            country: (body.origin_country?.isEmpty == false) ? body.origin_country : nil)
    }

    /// A person's page header.
    struct PersonProfile: Sendable {
        let photoURL: String?
        let biography: String?
        /// TMDB's department: "Acting", "Directing", …
        let department: String?
        let bornYear: String?
        let birthplace: String?
    }

    static func person(id: Int, language: String = preferredLanguage) async -> PersonProfile? {
        struct Response: Decodable {
            let biography: String?; let birthday: String?; let place_of_birth: String?
            let profile_path: String?; let known_for_department: String?
        }
        guard var body: Response = try? await get("/person/\(id)", query: ["language": language]) else { return nil }
        // No translation of the biography: TMDB's own (English).
        if (body.biography ?? "").isEmpty, language != "en-US",
           let english: Response = try? await get("/person/\(id)", query: ["language": "en-US"]) {
            body = Response(biography: english.biography, birthday: body.birthday,
                            place_of_birth: body.place_of_birth, profile_path: body.profile_path,
                            known_for_department: body.known_for_department)
        }
        let bio = body.biography?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PersonProfile(photoURL: imageURL(body.profile_path, size: "w500"),
                             biography: (bio?.isEmpty == false) ? bio : nil,
                             department: body.known_for_department,
                             bornYear: body.birthday.map { String($0.prefix(4)) }.flatMap { $0.count == 4 ? $0 : nil },
                             birthplace: (body.place_of_birth?.isEmpty == false) ? body.place_of_birth : nil)
    }

    /// A person's titles — their cast credits and what they directed, movies
    /// and shows — kept whole: a page of them is cut from it (`credits`).
    struct PersonCredits: Sendable {
        fileprivate struct Entry: Sendable {
            let raw: TMDBRawItem
            let popularity: Double
            let votes: Int
            let date: String
        }
        fileprivate let entries: [Entry]

        static let empty = PersonCredits(entries: [])

        func count(isMovie: Bool) -> Int { entries.filter { $0.raw.isMovie == isMovie }.count }
    }

    static func personCredits(id: Int, language: String = preferredLanguage) async -> PersonCredits {
        struct Response: Decodable { let cast: [Credit]?; let crew: [Credit]? }
        struct Credit: Decodable {
            let id: Int; let title: String?; let name: String?; let media_type: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?; let vote_count: Int?; let popularity: Double?
            let genre_ids: [Int]?; let job: String?
        }
        guard let body: Response = try? await get("/person/\(id)/combined_credits",
                                                   query: ["language": language]) else { return .empty }
        // Talk shows and news: the person appearing as themselves, not work.
        let notWork: Set<Int> = [10767, 10763]
        let credits = (body.cast ?? []) + (body.crew ?? []).filter { $0.job == "Director" }
        var seen = Set<String>()
        let entries: [PersonCredits.Entry] = credits.compactMap { c in
            let isTV = c.media_type?.lowercased() == "tv"
            // Movie and TV ids are separate TMDB namespaces: dedupe per
            // namespace or a film and a show sharing a number lose one.
            guard let title = c.title ?? c.name, !title.isEmpty,
                  c.poster_path != nil,
                  notWork.isDisjoint(with: c.genre_ids ?? []),
                  seen.insert((isTV ? "t" : "m") + String(c.id)).inserted else { return nil }
            let date = c.release_date ?? c.first_air_date ?? ""
            return PersonCredits.Entry(
                raw: TMDBRawItem(
                    tmdbID: c.id, isMovie: !isTV, name: title,
                    poster: imageURL(c.poster_path, size: "w500"),
                    background: imageURL(c.backdrop_path, size: "original"),
                    description: c.overview,
                    releaseInfo: date.isEmpty ? nil : String(date.prefix(4)),
                    rating: c.vote_average),
                popularity: c.popularity ?? 0, votes: c.vote_count ?? 0, date: date)
        }
        return PersonCredits(entries: entries)
    }

    /// A person's best-known titles, films and shows together — what they
    /// played (voice roles too) or directed, by votes and popularity (log
    /// scale) — Search's Top Results after the person.
    static func bestKnown(_ credits: PersonCredits, limit: Int) async -> [MetaItem] {
        let ranked = credits.entries.sorted {
            log1p(Double($0.votes)) + log1p($0.popularity) > log1p(Double($1.votes)) + log1p($1.popularity)
        }
        return Array(await mapToMetaItems(ranked.prefix(limit * 2).map(\.raw))
            .filter { $0.id.hasPrefix("tt") }.prefix(limit))
    }

    /// A page of a person's movies or shows in `sort`'s order.
    static func credits(_ credits: PersonCredits, isMovie: Bool, sort: BrowseSort, page: Int) async -> BrowsePage {
        let today = Date().formatted(.iso8601.year().month().day())
        var list = credits.entries.filter { $0.raw.isMovie == isMovie }
        let total = list.count
        switch sort {
        case .popular:
            list.sort { $0.popularity > $1.popularity }
        case .topRated:
            list = list.filter { $0.votes >= 50 }
            list.sort { ($0.raw.rating ?? 0) > ($1.raw.rating ?? 0) }
        case .newest:
            list = list.filter { !$0.date.isEmpty && $0.date <= today }
            list.sort { $0.date > $1.date }
        case .alphabetical:
            list.sort { $0.raw.name.localizedStandardCompare($1.raw.name) == .orderedAscending }
        }
        let start = (page - 1) * browsePageSize
        guard start < list.count else { return BrowsePage(items: [], total: total, hasMore: false) }
        let end = min(start + browsePageSize, list.count)
        return BrowsePage(items: await mapToMetaItems(list[start ..< end].map(\.raw)),
                          total: total, hasMore: end < list.count)
    }
}

// MARK: - Billboard picks (see `BillboardPicks`)

extension TMDBService {
    /// TMDB's recommendations for a title ("Because you watched …"), as titles
    /// with IMDb ids. Light: just the list, not the full detail call.
    static func recommendations(imdbID: String, type: String, limit: Int = 6) async -> [MetaItem] {
        guard let (tmdbID, isMovie) = await resolveTMDBID(from: imdbID, type: type) else { return [] }
        let path = isMovie ? "/movie/\(tmdbID)/recommendations" : "/tv/\(tmdbID)/recommendations"
        guard let body: PickList = try? await get(path, query: ["language": preferredLanguage]) else { return [] }
        return await mapToMetaItems(body.raw(defaultMovie: isMovie, limit: limit))
    }

    /// What's trending today, films and series together.
    static func trending(limit: Int = 15) async -> [MetaItem] {
        guard let body: PickList = try? await get("/trending/all/day",
                                                  query: ["language": preferredLanguage]) else { return [] }
        return await mapToMetaItems(body.raw(defaultMovie: true, limit: limit))
    }

    /// How well known a title is (TMDB's votes and popularity): Search's
    /// order.
    struct SearchFame: Sendable {
        let name: String
        let originalName: String?
        let year: Int?
        let isMovie: Bool
        let popularity: Double
        let votes: Int

        /// One number: votes (lasting fame) and popularity (right now),
        /// both on a log scale.
        var score: Double { log1p(Double(votes)) + log1p(popularity) }
    }

    /// One title from TMDB's search.
    struct SearchHit: Sendable {
        fileprivate let raw: TMDBRawItem
        let fame: SearchFame
    }

    /// TMDB's films and series for a search — two requests side by side
    /// (one page each): Search's suggestions, order and results. Empty
    /// without a key.
    static func search(_ query: String) async -> [SearchHit] {
        guard hasAPIKey else { return [] }
        struct Page: Decodable {
            struct Result: Decodable {
                let id: Int
                let title: String?
                let name: String?
                let original_title: String?
                let original_name: String?
                let release_date: String?
                let first_air_date: String?
                let poster_path: String?
                let backdrop_path: String?
                let overview: String?
                let vote_average: Double?
                let popularity: Double?
                let vote_count: Int?
            }
            let results: [Result]?
        }
        func search(_ kind: String) async -> [SearchHit] {
            let isMovie = kind == "movie"
            guard let page: Page = try? await get("/search/\(kind)", query: ["query": query, "language": preferredLanguage])
            else { return [] }
            return (page.results ?? []).compactMap { result in
                guard let name = result.title ?? result.name, !name.isEmpty else { return nil }
                let date = result.release_date ?? result.first_air_date
                let year = date.flatMap { Int($0.prefix(4)) }
                let raw = TMDBRawItem(
                    tmdbID: result.id, isMovie: isMovie, name: name,
                    poster: imageURL(result.poster_path, size: "w500"),
                    background: imageURL(result.backdrop_path, size: "w1280"),
                    description: result.overview, releaseInfo: year.map(String.init),
                    rating: result.vote_average.flatMap { $0 > 0 ? $0 : nil })
                return SearchHit(raw: raw, fame: SearchFame(
                    name: name, originalName: result.original_title ?? result.original_name, year: year,
                    isMovie: isMovie, popularity: result.popularity ?? 0, votes: result.vote_count ?? 0))
            }
        }
        async let movies = search("movie")
        async let series = search("tv")
        return await movies + series
    }

    /// TMDB's combined search (films, series, people — one list, its own
    /// order): Search's Top Results. Titles by their IMDb ids (none, or no
    /// picture: left out), people as `person:<id>` cards (no photo: left
    /// out) — in TMDB's order.
    static func searchMulti(_ query: String) async -> [MetaItem] {
        guard hasAPIKey else { return [] }
        struct Page: Decodable {
            struct Result: Decodable, Sendable {
                let id: Int
                let media_type: String?
                let title: String?
                let name: String?
                let release_date: String?
                let first_air_date: String?
                let poster_path: String?
                let backdrop_path: String?
                let profile_path: String?
                let overview: String?
                let vote_average: Double?
                let known_for_department: String?
            }
            let results: [Result]?
        }
        guard let page: Page = try? await get("/search/multi", query: ["query": query, "language": preferredLanguage])
        else { return [] }
        let results = (page.results ?? []).filter { ["movie", "tv", "person"].contains($0.media_type ?? "") }
        let ids = await boundedConcurrentMap(results, limit: imdbResolveWindow) { result in
            result.media_type == "person" ? "" : await imdbID(tmdbID: result.id, isMovie: result.media_type == "movie") ?? ""
        }
        var seen = Set<String>()
        return results.indices.compactMap { index -> MetaItem? in
            let result = results[index]
            guard let name = result.title ?? result.name, !name.isEmpty else { return nil }
            if result.media_type == "person" {
                guard let photo = imageURL(result.profile_path, size: "w300") else { return nil }
                return MetaItem(id: "person:\(result.id)", type: "person", name: name, poster: photo,
                                background: nil, releaseInfo: result.known_for_department)
            }
            let id = ids[index]
            let poster = imageURL(result.poster_path, size: "w500")
            let background = imageURL(result.backdrop_path, size: "w1280")
            guard id.hasPrefix("tt"), poster != nil || background != nil, seen.insert(id).inserted else { return nil }
            return MetaItem(id: id, type: result.media_type == "movie" ? "movie" : "series", name: name,
                            poster: poster, background: background,
                            logo: "https://images.metahub.space/logo/medium/\(id)/img",
                            description: result.overview,
                            releaseInfo: (result.release_date ?? result.first_air_date).map { String($0.prefix(4)) },
                            imdbRating: result.vote_average.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil })
        }
    }

    /// Search's titles, playable: by their IMDb ids (what the stream
    /// add-ons take) — those without one, or without any picture, left out.
    static func playable(_ hits: [SearchHit]) async -> [MetaItem] {
        let pictured = hits.map(\.raw).filter { $0.poster != nil || $0.background != nil }
        return await mapToMetaItems(pictured).filter { $0.id.hasPrefix("tt") }
    }

    /// A TMDB result list (recommendations, trending).
    private struct PickList: Decodable {
        struct Result: Decodable {
            let id: Int
            let title: String?
            let name: String?
            let media_type: String?
            let poster_path: String?
            let backdrop_path: String?
            let overview: String?
            let release_date: String?
            let first_air_date: String?
            let vote_average: Double?
            let genre_ids: [Int]?
        }
        let results: [Result]?

        /// Films and series only (trending also lists people), up to `limit`.
        func raw(defaultMovie: Bool, limit: Int) -> [TMDBRawItem] {
            (results ?? []).compactMap { result -> TMDBRawItem? in
                let isMovie: Bool
                switch result.media_type {
                case "movie": isMovie = true
                case "tv": isMovie = false
                case nil: isMovie = defaultMovie
                default: return nil
                }
                guard let name = isMovie ? result.title : result.name, !name.isEmpty else { return nil }
                let date = isMovie ? result.release_date : result.first_air_date
                let genres = (result.genre_ids ?? []).compactMap { isMovie ? movieGenres[$0] : tvGenres[$0] }
                return TMDBRawItem(
                    tmdbID: result.id, isMovie: isMovie, name: name,
                    poster: imageURL(result.poster_path, size: "w500"),
                    background: imageURL(result.backdrop_path, size: "original"),
                    description: result.overview,
                    releaseInfo: date.map { String($0.prefix(4)) },
                    rating: result.vote_average,
                    genres: genres.isEmpty ? nil : genres
                )
            }
            .prefix(limit)
            .map { $0 }
        }
    }

}
