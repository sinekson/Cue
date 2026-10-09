import Foundation

// MARK: - Settings

/// MDBList settings, mirroring the Android `MDBListSettings`. Requires the
/// user's own MDBList API key (there's no shared key — MDBList is per-account).
struct MDBListSettings: Codable, Equatable {
    var enabled: Bool = false
    var apiKey: String = ""
    var showTrakt = true
    var showImdb = true
    var showTmdb = true
    var showLetterboxd = true
    var showTomatoes = true
    var showAudience = true
    var showMetacritic = true
    var showMyAnimeList = true
    /// The sources' order (raw values): ratings show in it, and the billboard
    /// shows the first three.
    var order: [String] = MDBListSettings.defaultOrder.map(\.rawValue)

    /// IMDb first; MyAnimeList second — only anime have one, so it shows for
    /// them and everything else falls through to the next.
    static let defaultOrder: [MDBListProvider] = [
        .imdb, .myanimelist, .tomatoes, .letterboxd, .metacritic, .audience, .tmdb, .trakt,
    ]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, apiKey, showTrakt, showImdb, showTmdb, showLetterboxd
        case showTomatoes, showAudience, showMetacritic, showMyAnimeList, order
    }

    /// Tolerant per-field decode, exactly like `PlayerSettingsStore`: adding a
    /// field in a future release must not make an existing blob undecodable
    /// and silently reset the user's API key and source toggles to defaults
    /// (the store has no unreadable-blob guard).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MDBListSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? d.apiKey
        showTrakt = (try? c.decode(Bool.self, forKey: .showTrakt)) ?? d.showTrakt
        showImdb = (try? c.decode(Bool.self, forKey: .showImdb)) ?? d.showImdb
        showTmdb = (try? c.decode(Bool.self, forKey: .showTmdb)) ?? d.showTmdb
        showLetterboxd = (try? c.decode(Bool.self, forKey: .showLetterboxd)) ?? d.showLetterboxd
        showTomatoes = (try? c.decode(Bool.self, forKey: .showTomatoes)) ?? d.showTomatoes
        showAudience = (try? c.decode(Bool.self, forKey: .showAudience)) ?? d.showAudience
        showMetacritic = (try? c.decode(Bool.self, forKey: .showMetacritic)) ?? d.showMetacritic
        showMyAnimeList = (try? c.decode(Bool.self, forKey: .showMyAnimeList)) ?? d.showMyAnimeList
        order = (try? c.decode([String].self, forKey: .order)) ?? d.order
    }

    static let `default` = MDBListSettings()

    /// A key means on (there's no separate switch).
    var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Every source, in the chosen order (ones the order doesn't name yet at
    /// the end).
    var orderedProviders: [MDBListProvider] {
        let listed = order.compactMap(MDBListProvider.init(rawValue:))
        return listed + MDBListProvider.allCases.filter { !listed.contains($0) }
    }

    /// The sources that show, in order.
    var shownProviders: [MDBListProvider] { orderedProviders.filter(isShown) }

    func isShown(_ provider: MDBListProvider) -> Bool {
        switch provider {
        case .trakt: return showTrakt
        case .imdb: return showImdb
        case .tmdb: return showTmdb
        case .letterboxd: return showLetterboxd
        case .tomatoes: return showTomatoes
        case .audience: return showAudience
        case .metacritic: return showMetacritic
        case .myanimelist: return showMyAnimeList
        }
    }

    mutating func setShown(_ provider: MDBListProvider, _ shown: Bool) {
        switch provider {
        case .trakt: showTrakt = shown
        case .imdb: showImdb = shown
        case .tmdb: showTmdb = shown
        case .letterboxd: showLetterboxd = shown
        case .tomatoes: showTomatoes = shown
        case .audience: showAudience = shown
        case .metacritic: showMetacritic = shown
        case .myanimelist: showMyAnimeList = shown
        }
    }

    /// One step up (−1) or down (+1).
    mutating func move(_ provider: MDBListProvider, by step: Int) {
        var providers = orderedProviders
        guard let index = providers.firstIndex(of: provider),
              providers.indices.contains(index + step) else { return }
        providers.swapAt(index, index + step)
        order = providers.map(\.rawValue)
    }
}

@MainActor
final class MDBListSettingsStore: ObservableObject {
    @Published var settings: MDBListSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    private static let key = "cue.mdblist.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(MDBListSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

// MARK: - Ratings model

/// Aggregate ratings across sources (0–10 for imdb/tmdb/letterboxd/trakt-ish,
/// (and MyAnimeList, 0–10), 0–100 percentages for tomatoes/audience/metacritic — MDBList returns them
/// pre-scaled per source).
struct MDBListRatings: Equatable, Codable, Sendable {
    var trakt: Double?
    var imdb: Double?
    var tmdb: Double?
    var letterboxd: Double?
    var tomatoes: Double?
    var audience: Double?
    var metacritic: Double?
    var myanimelist: Double?

    var isEmpty: Bool {
        trakt == nil && imdb == nil && tmdb == nil && letterboxd == nil
            && tomatoes == nil && audience == nil && metacritic == nil && myanimelist == nil
    }

    /// Ordered, display-ready entries (matches the Android hero ratings row).
    func entries(settings: MDBListSettings) -> [MDBListRatingEntry] {
        settings.shownProviders.compactMap { provider in
            value(of: provider).map { MDBListRatingEntry(provider: provider, text: provider.format($0)) }
        }
    }

    func value(of provider: MDBListProvider) -> Double? {
        switch provider {
        case .trakt: return trakt
        case .imdb: return imdb
        case .tmdb: return tmdb
        case .letterboxd: return letterboxd
        case .tomatoes: return tomatoes
        case .audience: return audience
        case .metacritic: return metacritic
        case .myanimelist: return myanimelist
        }
    }
}

struct MDBListRatingEntry: Identifiable, Equatable {
    let provider: MDBListProvider
    let text: String
    var id: String { provider.rawValue }
}

enum MDBListProvider: String, CaseIterable, Identifiable {
    // The raw value is MDBList's name for the source in `/rating/…`.
    case trakt, imdb, tmdb, letterboxd, tomatoes, audience, metacritic, myanimelist
    var id: String { rawValue }

    /// Short badge label shown next to the score.
    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .imdb: return "IMDb"
        case .tmdb: return "TMDB"
        case .letterboxd: return "LBXD"
        case .tomatoes: return "RT"
        case .audience: return "RT🍿"
        case .metacritic: return "MC"
        case .myanimelist: return "MAL"
        }
    }

    var fullName: String {
        switch self {
        case .trakt: return "Trakt"
        case .imdb: return "IMDb"
        case .tmdb: return "TMDB"
        case .letterboxd: return "Letterboxd"
        case .tomatoes: return "Rotten Tomatoes"
        case .audience: return "RT Audience"
        case .metacritic: return "Metacritic"
        case .myanimelist: return "MyAnimeList"
        }
    }

    /// Matches Android `formatMDBListRating`: 0–10 scores keep one decimal,
    /// percentage sources show a whole number (or one decimal if fractional).
    func format(_ rating: Double) -> String {
        switch self {
        case .imdb, .letterboxd, .myanimelist:
            return String(format: "%.1f", rating)
        case .tmdb:
            // MDBList gives TMDB out of 100: "77", not "77.0".
            return String(Int(rating.rounded()))
        default:
            return rating.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(rating))
                : String(format: "%.1f", rating)
        }
    }
}

// MARK: - Usage

/// MDBList's daily request limit as its last answer reported it (every
/// answer carries it in its headers — knowing it costs no request). Shown on
/// Settings → Developer.
@MainActor
final class MDBListUsage: ObservableObject {
    static let shared = MDBListUsage()

    struct Snapshot: Codable, Equatable {
        var limit: Int
        var remaining: Int
        var resetsAt: Date?
        var seenAt: Date
    }

    @Published private(set) var snapshot: Snapshot?
    private static let key = "cue.mdblist.usage"

    private init() {
        snapshot = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }

    nonisolated static func note(_ response: HTTPURLResponse) {
        func header(_ name: String) -> Double? {
            response.value(forHTTPHeaderField: name).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard let limit = header("X-RateLimit-Limit"), let remaining = header("X-RateLimit-Remaining") else { return }
        // The reset as a time stamp, or as seconds from now.
        let resetsAt = header("X-RateLimit-Reset").map { value in
            value > 1_000_000_000 ? Date(timeIntervalSince1970: value) : Date().addingTimeInterval(value)
        }
        let snapshot = Snapshot(limit: Int(limit), remaining: Int(remaining), resetsAt: resetsAt, seenAt: Date())
        Task { @MainActor in
            shared.snapshot = snapshot
            if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: key) }
        }
    }
}

// MARK: - Service

/// MDBList ratings client. ONE request gives a title's every rating
/// (`GET /imdb/{movie|show}/{id}`), and one request gives up to 200 titles'
/// (`POST /imdb/{movie|show}`, for the billboard's picks). All sources are
/// kept; which show, and in what order, is decided when they're shown — so
/// a source switched on later needs no new request.
enum MDBListService {
    private static let base = "https://api.mdblist.com"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private struct CacheEntry { let ratings: MDBListRatings; let expiresAt: Date }
    // Guarded by `cacheLock`: `ratings(...)` runs concurrently across catalog
    // items, and a plain Dictionary is not safe under concurrent mutation.
    private static let cacheLock = NSLock()

    /// MDBList said "too many requests" (429): no more requests until this
    /// time — its Retry-After, else a quarter of an hour.
    nonisolated(unsafe) private static var limitedUntil: Date?
    private static let backoff: TimeInterval = 15 * 60
    private static var isLimited: Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return limitedUntil.map { $0 > Date() } ?? false
    }
    private static func markLimited(_ response: HTTPURLResponse) {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        cacheLock.lock(); defer { cacheLock.unlock() }
        limitedUntil = Date().addingTimeInterval(retryAfter ?? backoff)
    }
    private static var cache: [String: CacheEntry] = [:]
    /// Ratings for a day, in memory and on disk: they don't need to change
    /// mid-day, and every request counts against a daily limit.
    private static let disk = DiskCache<MDBListRatings>(name: "mdblist-ratings-v2")
    private static let ttl: TimeInterval = 24 * 60 * 60
    /// Kept this long (stale-while-revalidate, docs/LOADING-PLAN.md §2): past
    /// `ttl` they're still shown at once and asked again in the background.
    private static let keep: TimeInterval = 14 * 24 * 60 * 60
    private static let cacheLimit = 512

    private static func cacheKey(_ imdbID: String, _ mediaType: String) -> String { "\(mediaType):\(imdbID)" }

    private static func cachedEntry(_ key: String) -> CacheEntry? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key]
    }
    private static func storeEntry(_ entry: CacheEntry, for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache.count > cacheLimit {
            for key in Array(cache.keys.prefix(cache.count - cacheLimit / 2)) {
                cache.removeValue(forKey: key)
            }
        }
        cache[key] = entry
    }

    /// Remembered for a day — an empty answer too (MDBList knows no ratings
    /// for it), so it isn't asked again.
    private static func store(_ ratings: MDBListRatings, for key: String) async {
        storeEntry(CacheEntry(ratings: ratings, expiresAt: Date().addingTimeInterval(ttl)), for: key)
        await disk.store(ratings, for: key)
    }

    /// Cached ratings: `.some(nil)` = known to have none; nil = not cached.
    /// `stale`: older than a day (still shown — ask again in the background).
    private static func cached(_ key: String) async -> MDBListRatings?? {
        await cachedWithAge(key)?.ratings
    }

    private static func cachedWithAge(_ key: String) async -> (ratings: MDBListRatings?, stale: Bool)? {
        if let hit = cachedEntry(key), hit.expiresAt > Date() {
            return (hit.ratings.isEmpty ? nil : hit.ratings, false)
        }
        if let (stored, age) = await disk.entry(for: key, keep: keep) {
            let stale = age > ttl
            storeEntry(CacheEntry(ratings: stored,
                                  expiresAt: Date().addingTimeInterval(stale ? 0 : ttl - age)), for: key)
            return (stored.isEmpty ? nil : stored, stale)
        }
        return nil
    }

    /// Asked again, quietly (a stale entry was just shown) — once per title
    /// per session.
    private static func refreshInBackground(imdbID: String, type: String, key: String,
                                            settings: MDBListSettings) {
        let first = cacheLock.withLock { refreshing.insert(key).inserted }
        guard first else { return }
        Task.detached(priority: .utility) {
            guard await mayAsk(settings),
                  let url = url("/imdb/\(mediaType(type))/\(imdbID)", apiKey: settings.apiKey),
                  let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse else { return }
            MDBListUsage.note(http)
            if http.statusCode == 429 { markLimited(http) }
            guard (200..<300).contains(http.statusCode) else { return }
            let ratings = (try? JSONDecoder().decode(Media.self, from: data))?.ratings ?? MDBListRatings()
            await store(ratings, for: key)
        }
    }
    nonisolated(unsafe) private static var refreshing = Set<String>()

    /// No requests: no key, limited, or Render Lab → MDBList off.
    private static func mayAsk(_ settings: MDBListSettings) async -> Bool {
        guard settings.isConfigured, !isLimited else { return false }
        return await !MainActor.run(body: { RenderProbe.shared.flags.noMDBList })
    }

    private static func mediaType(_ type: String) -> String {
        (type == "series" || type == "tv") ? "show" : "movie"
    }

    /// Validate an API key via `GET /user`.
    static func validate(apiKey: String) async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              var comps = URLComponents(string: base + "/user") else { return false }
        comps.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = comps.url else { return false }
        guard let (_, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return false }
        MDBListUsage.note(http)
        return (200..<300).contains(http.statusCode)
    }

    /// Ratings for any title: its imdb id directly, or resolved through
    /// TMDB (for catalogs with other ids). Detail page and billboard alike.
    static func ratings(for meta: MetaItem, settings: MDBListSettings) async -> MDBListRatings? {
        guard settings.isConfigured else { return nil }
        let imdbID: String?
        if meta.id.hasPrefix("tt") {
            imdbID = meta.id
        } else if let (tid, isMovie) = await TMDBService.resolveTMDBID(from: meta.id, type: meta.type) {
            imdbID = await TMDBService.imdbID(tmdbID: tid, isMovie: isMovie)
        } else {
            imdbID = nil
        }
        guard let imdbID else { return nil }
        return await ratings(imdbID: imdbID, type: meta.type, settings: settings)
    }

    /// A title's ratings, every source. Needs an imdb `tt…` id.
    static func ratings(imdbID: String, type: String, settings: MDBListSettings) async -> MDBListRatings? {
        guard settings.isConfigured, imdbID.hasPrefix("tt") else { return nil }
        let mediaType = mediaType(type)
        let key = cacheKey(imdbID, mediaType)
        if let known = await cachedWithAge(key) {
            if known.stale { refreshInBackground(imdbID: imdbID, type: type, key: key, settings: settings) }
            return known.ratings
        }
        guard await mayAsk(settings),
              let url = url("/imdb/\(mediaType)/\(imdbID)", apiKey: settings.apiKey),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return nil }
        MDBListUsage.note(http)
        if http.statusCode == 429 { markLimited(http) }
        // Only a definitive answer is remembered; a failure is asked again.
        guard (200..<300).contains(http.statusCode) else { return nil }
        let ratings = (try? JSONDecoder().decode(Media.self, from: data))?.ratings ?? MDBListRatings()
        await store(ratings, for: key)
        return ratings.isEmpty ? nil : ratings
    }

    /// Fetches the ratings of many titles at once — one request per 200 of
    /// a kind — so the ones shown next (the billboard's picks) are already
    /// there. Titles without an imdb id, or already cached, are skipped.
    static func prefetch(_ metas: [MetaItem], settings: MDBListSettings) async {
        guard settings.isConfigured else { return }
        var wanted: [String: [String]] = [:]
        for meta in metas where meta.id.hasPrefix("tt") {
            let mediaType = mediaType(meta.type)
            // (Missing — or stale: refreshed in the same batch.)
            let known = await cachedWithAge(cacheKey(meta.id, mediaType))
            guard known == nil || known?.stale == true,
                  wanted[mediaType]?.contains(meta.id) != true else { continue }
            wanted[mediaType, default: []].append(meta.id)
        }
        for (mediaType, ids) in wanted {
            for start in stride(from: 0, to: ids.count, by: 200) {
                let batch = Array(ids[start..<min(start + 200, ids.count)])
                guard await mayAsk(settings),
                      let url = url("/imdb/\(mediaType)", apiKey: settings.apiKey) else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": batch])
                guard let (data, response) = try? await session.data(for: request),
                      let http = response as? HTTPURLResponse else { return }
                MDBListUsage.note(http)
                if http.statusCode == 429 { markLimited(http) }
                guard (200..<300).contains(http.statusCode),
                      let items = try? JSONDecoder().decode([Media].self, from: data) else { return }
                var byID: [String: MDBListRatings] = [:]
                for item in items { if let id = item.ids?.imdb { byID[id] = item.ratings } }
                // Asked for and not in the answer: MDBList doesn't know it.
                for id in batch {
                    await store(byID[id] ?? MDBListRatings(), for: cacheKey(id, mediaType))
                }
            }
        }
    }

    private static func url(_ path: String, apiKey: String) -> URL? {
        var comps = URLComponents(string: base + path)
        comps?.queryItems = [URLQueryItem(name: "apikey", value: apiKey.trimmingCharacters(in: .whitespaces))]
        return comps?.url
    }

    /// A title as MDBList describes it — only what's needed: its imdb id and
    /// its ratings (`source` + `value`, on each source's own scale).
    private struct Media: Decodable {
        struct IDs: Decodable { let imdb: String? }
        struct Rating: Decodable { let source: String; let value: Double? }
        let ids: IDs?
        private let ratingList: [Rating]?

        enum CodingKeys: String, CodingKey { case ids, ratingList = "ratings" }

        var ratings: MDBListRatings {
            var out = MDBListRatings()
            for rating in ratingList ?? [] {
                guard let value = rating.value else { continue }
                switch rating.source {
                case "imdb": out.imdb = value
                case "tmdb": out.tmdb = value
                case "trakt": out.trakt = value
                case "letterboxd": out.letterboxd = value
                case "tomatoes": out.tomatoes = value
                case "popcorn", "audience": out.audience = value
                case "metacritic": out.metacritic = value
                case "myanimelist", "mal": out.myanimelist = value
                default: break
                }
            }
            return out
        }
    }
}
