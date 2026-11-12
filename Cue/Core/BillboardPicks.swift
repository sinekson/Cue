import Foundation

/// One title on the billboard, with why it's there.
struct BillboardPick: Identifiable, Equatable {
    let item: MetaItem
    let reason: BillboardReason?
    var id: String { item.id }
}

/// Why a title is on the billboard — shown small above its logo: what kind
/// of pick (muted) and the detail that makes it concrete (white); trending
/// with its rank.
enum BillboardReason: Equatable {
    case newEpisode(season: Int, episode: Int, aired: Date)
    case newSeason(season: Int, aired: Date)
    case because(title: String)
    /// Today's trending rank (1 = first).
    case trending(rank: Int)
    /// From one of Home's rows (no picks without TMDB).
    case row(title: String)

    /// The kind of pick: "NEW EPISODE", "BECAUSE YOU WATCHED", …
    var lead: String {
        switch self {
        case .newEpisode: return "New episode"
        case .newSeason: return "New season"
        case .because: return "Because you watched"
        case .trending: return "Trending today"
        case .row(let title): return title
        }
    }

    /// The detail: "S3 E7 · Yesterday", "Dark", …
    var detail: String? {
        switch self {
        case .newEpisode(let season, let episode, let aired):
            return "S\(season) E\(episode) · \(Self.day(aired))"
        case .newSeason(let season, let aired):
            return "Season \(season) · \(Self.day(aired))"
        case .because(let title):
            return title
        case .trending, .row:
            return nil
        }
    }

    /// "Today", "Yesterday", the weekday within a week, else the date.
    private static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEEE" : "d MMM")
        return formatter.string(from: date)
    }
}

/// THE BILLBOARD'S PICKS — Cue's own, from what you watch and TMDB, no
/// catalog needed:
/// - New for you, first: a new episode or season of a show you're watching,
///   have watched or saved (aired in the last `newWindow`, not seen yet).
/// - Then, alternating: Because you watched (TMDB's recommendations for your
///   last few titles) and Trending (today's, minus what you've seen) — so
///   paging through varies.
/// Every pick has a backdrop (and a logo where one exists). Without TMDB
/// only the new episodes; with too little to go on, the highlights of
/// Home's rows fill in.
@MainActor
enum BillboardPicks {
    /// What the picks are made from, read from the stores.
    @MainActor
    struct History {
        /// Series you follow: in Continue Watching, watched or saved — most
        /// recent first.
        let following: [MetaItem]
        /// Your last few titles, for "Because you watched".
        let recent: [MetaItem]
        /// Everything you've watched or started (by title id).
        let seen: Set<String>
        /// Whether an episode is watched.
        let watchedEpisode: @MainActor (_ id: String, _ season: Int, _ episode: Int) -> Bool
        /// Every title watched, started or saved: how much and when (what
        /// Cue's own rows read a taste from, `CueRows.Taste`).
        let watches: [Watch]

        struct Watch: Sendable {
            let id: String
            let type: String
            let last: Date
            /// Episodes watched; a film, 1 once watched.
            var watched = 0
            var started = false
            var saved = false
        }

        init(progress: ProgressStore, watched: WatchedStore, library: LibraryStore) {
            let started = progress.continueWatching
            // Most recent first: started titles and watched ones, by date.
            var events: [(id: String, type: String, name: String, date: Date, item: MetaItem?)] = []
            for entry in started {
                events.append((entry.metaID, entry.type, entry.name, entry.updatedAt,
                               MetaItem(id: entry.metaID, type: entry.type, name: entry.name,
                                        poster: entry.poster, background: entry.background,
                                        logo: entry.logo)))
            }
            for item in watched.items.values {
                events.append((item.contentID, item.contentType, item.title, item.watchedAt, nil))
            }
            events.sort { $0.date > $1.date }

            var seenIDs = Set<String>()
            var recent: [MetaItem] = []
            var following: [MetaItem] = []
            var followed = Set<String>()
            for event in events where seenIDs.insert(event.id).inserted {
                let item = event.item ?? MetaItem(id: event.id, type: event.type, name: event.name)
                if recent.count < BillboardPicks.seedCount { recent.append(item) }
                if item.isSeries, followed.insert(item.id).inserted { following.append(item) }
            }
            for saved in library.sorted where saved.type == "series" && followed.insert(saved.id).inserted {
                following.append(MetaItem(id: saved.id, type: saved.type, name: saved.name,
                                          poster: saved.poster, background: saved.background,
                                          description: saved.description))
            }
            self.following = following
            self.recent = recent
            self.seen = seenIDs
            self.watchedEpisode = { watched.isWatched(contentID: $0, season: $1, episode: $2) }

            var watches: [String: Watch] = [:]
            func note(_ id: String, _ type: String, _ date: Date, _ change: (inout Watch) -> Void) {
                var watch = watches[id] ?? Watch(id: id, type: type, last: date)
                if date > watch.last { watch = Watch(id: id, type: type, last: date, watched: watch.watched,
                                                     started: watch.started, saved: watch.saved) }
                change(&watch)
                watches[id] = watch
            }
            for entry in started { note(entry.metaID, entry.type, entry.updatedAt) { $0.started = true } }
            for item in watched.items.values { note(item.contentID, item.contentType, item.watchedAt) { $0.watched += 1 } }
            for saved in library.sorted { note(saved.id, saved.type, saved.addedAt) { $0.saved = true } }
            self.watches = watches.values.sorted { $0.last > $1.last }
        }
    }

    /// How many picks there are (the tabs filter them by type).
    static let count = 10
    static let newCap = 4
    static let becauseCap = 4
    static let seedCount = 3
    /// "New" means aired within this long.
    static let newWindow: TimeInterval = 10 * 24 * 60 * 60
    /// Shows checked for a new episode (a request each).
    static let followCap = 12

    /// The picks, best first; `fallback` (Home's highlights) fills in.
    static func make(history: History, addonManager: AddonManager, tmdb: Bool,
                     fallback: [BillboardPick]) async -> [BillboardPick] {
        var picks: [BillboardPick] = []
        var used = Set<String>()
        func add(_ pick: BillboardPick) {
            guard pick.item.background != nil, used.insert(pick.id).inserted else { return }
            picks.append(BillboardPick(item: withLogo(pick.item), reason: pick.reason))
        }

        // From the add-ons' episode lists: no TMDB needed.
        for pick in await newForYou(history, addonManager: addonManager) { add(pick) }

        if tmdb {

            var because: [BillboardPick] = []
            for seed in history.recent where because.count < becauseCap {
                // Watched rows synced from elsewhere can carry only the id
                // as their name: ask TMDB, or leave this seed out.
                guard let name = await displayName(of: seed) else { continue }
                let recommended = await TMDBService.recommendations(imdbID: seed.id, type: seed.type)
                for item in recommended.filter({ !history.seen.contains($0.id) && $0.background != nil }).prefix(2)
                where because.count < becauseCap {
                    because.append(BillboardPick(item: item, reason: .because(title: name)))
                }
            }

            // The rank is TMDB's, before unseen filtering — the real one.
            // Generous: the Movies / Series tabs filter by type.
            let trending = await TMDBService.trending().enumerated().compactMap { index, item in
                history.seen.contains(item.id) ? nil
                    : BillboardPick(item: item, reason: .trending(rank: index + 1))
            }

            // Alternating, so paging through varies.
            for index in 0..<max(because.count, trending.count) {
                if index < because.count { add(because[index]) }
                if index < trending.count { add(trending[index]) }
            }
        }
        for pick in fallback { add(pick) }
        let pictured = await withTMDBPictures(picks)
        return CueRows.isOn ? await withTMDBLogos(pictured) : pictured
    }

    /// Cue's own rows: each pick's logo TMDB's, as the rows' (MetaHub's
    /// where TMDB has none).
    private static func withTMDBLogos(_ picks: [BillboardPick]) async -> [BillboardPick] {
        let logos = await withTaskGroup(of: (String, String?).self) { group in
            for pick in picks {
                let (id, type) = (pick.item.id, pick.item.type)
                group.addTask { (id, await TMDBService.cueLogo(imdbID: id, type: type)) }
            }
            var all: [String: String] = [:]
            for await (id, logo) in group { if let logo { all[id] = logo } }
            return all
        }
        return picks.map { pick in
            guard let logo = logos[pick.id] else { return pick }
            let item = pick.item
            return BillboardPick(item: MetaItem(id: item.id, type: item.type, name: item.name, poster: item.poster,
                                                background: item.background, logo: logo,
                                                description: item.description, releaseInfo: item.releaseInfo,
                                                imdbRating: item.imdbRating, runtime: item.runtime, genres: item.genres,
                                                cast: item.cast, videos: item.videos),
                                 reason: pick.reason)
        }
    }

    /// Each pick's picture TMDB's (`TitlePictures` — Details opened from
    /// here keeps it); the add-on's where TMDB has none.
    private static func withTMDBPictures(_ picks: [BillboardPick]) async -> [BillboardPick] {
        let chosen = await withTaskGroup(of: (String, String?).self) { group in
            for pick in picks {
                group.addTask { (pick.id, await TitlePictures.shared.picture(for: pick.item)) }
            }
            var all: [String: String] = [:]
            for await (id, url) in group { if let url { all[id] = url } }
            return all
        }
        return picks.map { pick in
            guard let url = chosen[pick.id] else { return pick }
            let item = pick.item
            return BillboardPick(item: MetaItem(id: item.id, type: item.type, name: item.name, poster: item.poster,
                                                background: url, logo: item.logo,
                                                description: item.description, releaseInfo: item.releaseInfo,
                                                imdbRating: item.imdbRating, runtime: item.runtime, genres: item.genres,
                                                cast: item.cast, videos: item.videos),
                                 reason: pick.reason)
        }
    }

    /// A title's name for a reason line — nil when all we have is its id.
    private static func displayName(of item: MetaItem) async -> String? {
        let looksLikeID = item.name.isEmpty || item.name == item.id
            || item.name.range(of: #"^tt\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard looksLikeID else { return item.name }
        return await TMDBService.metaItem(imdbID: item.id, type: item.type)?.name
    }

    /// New episodes / seasons of the shows you follow, newest first — from
    /// each show's episode list (`SeriesEpisodes`, the Episodes page's), so
    /// "S3 E7" here is the S3 E7 there.
    private static func newForYou(_ history: History, addonManager: AddonManager) async -> [BillboardPick] {
        let now = Date()
        var hits: [(meta: MetaItem, episode: MetaVideo, aired: Date)] = []
        for show in history.following.prefix(followCap) {
            let meta = await SeriesEpisodes.fullMeta(for: show, addonManager: addonManager)
            guard let latest = SeriesEpisodes.latestAired(in: meta),
                  let season = latest.episode.season, let number = latest.episode.episode,
                  now.timeIntervalSince(latest.aired) <= newWindow,
                  !history.watchedEpisode(show.id, season, number) else { continue }
            hits.append((meta, latest.episode, latest.aired))
        }
        hits.sort { $0.aired > $1.aired }

        return hits.prefix(newCap).map { hit in
            // The add-on's full title; Continue Watching's artwork where it
            // has none.
            let show = history.following.first { $0.id == hit.meta.id }
            let item = MetaItem(
                id: hit.meta.id, type: "series", name: hit.meta.name,
                poster: hit.meta.poster ?? show?.poster,
                background: hit.meta.background ?? show?.background,
                logo: hit.meta.logo ?? show?.logo,
                description: hit.meta.description, releaseInfo: hit.meta.releaseInfo,
                imdbRating: hit.meta.imdbRating, runtime: hit.meta.runtime, genres: hit.meta.genres)
            let season = hit.episode.season ?? 1, number = hit.episode.episode ?? 1
            let reason: BillboardReason = number == 1 && season > 1
                ? .newSeason(season: season, aired: hit.aired)
                : .newEpisode(season: season, episode: number, aired: hit.aired)
            return BillboardPick(item: item, reason: reason)
        }
    }

    /// MetaHub's logo for an IMDb title (nil for other ids).
    static func metaHubLogo(_ id: String) -> String? {
        id.hasPrefix("tt") ? "https://images.metahub.space/logo/medium/\(id)/img" : nil
    }

    /// A logo for IMDb titles that came without one (MetaHub's; the billboard
    /// falls back to the name when it doesn't load).
    private static func withLogo(_ item: MetaItem) -> MetaItem {
        guard item.logo == nil, item.id.hasPrefix("tt") else { return item }
        return MetaItem(id: item.id, type: item.type, name: item.name, poster: item.poster,
                        background: item.background,
                        logo: metaHubLogo(item.id),
                        description: item.description, releaseInfo: item.releaseInfo,
                        imdbRating: item.imdbRating, runtime: item.runtime, genres: item.genres,
                        cast: item.cast, videos: item.videos)
    }
}

/// CUE'S OWN ROWS — Home's, Movies' and Series' rows made by Cue from TMDB
/// and what you watch, not the add-ons' catalogs (Developer → Cue's own
/// rows). A taste is read from your watching (`Taste`); a catalogue of named
/// rows (`catalogue`) is scored against it, with a daily seeded share of
/// chance so rows rotate; each row's titles are ordered for you. Each tab
/// has its own rows (`tabs`). Built on a new day, after `rebuildAge`, or when
/// your last titles changed; saved per profile, so a launch paints the last
/// ones at once and new ones show on the next load, never mid-browse.
enum CueRows {
    @MainActor static var isOn: Bool { PerformanceSettingsStore.shared.settings.cueRows }

    typealias Title = TMDBService.CueTitle
    typealias Traits = TMDBService.TitleTraits
    typealias Watch = BillboardPicks.History.Watch

    struct Row: Codable, Sendable {
        let id: String
        let title: String
        /// "home", "movie", "series"; nil: every tab.
        let tabs: [String]?
        let items: [MetaItem]
    }

    /// Why a row is there (Developer → Why These Rows).
    struct Why: Codable, Sendable {
        let tab: String
        let title: String
        let reason: String
    }

    struct TasteLine: Codable, Sendable {
        let label: String
        let share: Double
    }

    struct Saved: Codable, Sendable {
        let builtAt: Date
        /// The titles "Because you watched" was made from.
        let seeds: [String]
        let rows: [Row]
        /// The day the rows were chosen for; the catalogue's rows shown
        /// that day, and the day before's (rotated away from).
        let day: String
        let picked: [String]
        let previous: [String]
        /// What the taste was read from, for the Why page.
        let titles: Int
        let taste: [TasteLine]
        let why: [Why]
        /// Titles left out for being passed over, by name.
        let passedOver: [String]
    }

    static let rebuildAge: TimeInterval = 6 * 60 * 60
    /// A row needs this many titles to show; your own (Pick Back Up, Watch
    /// Again) fewer: they're about you, not a catalogue running out.
    static let minimumTitles = 10
    static let minimumOwn = 5
    static let rowLength = 25
    /// What a list is fetched until (unseen titles), at most `maxPages` pages:
    /// room for a title being in two rows already.
    static let fetchUntil = 30
    static let maxPages = 3

    private static var fileURL: URL {
        let profile = UserDefaults.standard.object(forKey: ProfileStore.activeKey) as? Int ?? 1
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueCache/cue-rows/p\(profile).json")
    }

    static func saved() async -> Saved? {
        let url = fileURL
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Saved.self, from: data)
        }.value
    }

    static func save(_ saved: Saved) {
        let url = fileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }

    @MainActor static func seeds(_ history: BillboardPicks.History?) -> [String] {
        (history?.recent ?? []).map(\.id)
    }

    /// Time for new rows: none saved, older than `rebuildAge` or from another
    /// day, or made from other titles.
    static func due(_ saved: Saved?, seeds: [String], now: Date = Date()) -> Bool {
        guard let saved else { return true }
        return now.timeIntervalSince(saved.builtAt) > rebuildAge
            || saved.day != dayKey(now)
            || saved.seeds != seeds
    }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The country for cinemas and services.
    static var region: String { Locale.current.region?.identifier ?? "US" }

    /// The same chance all day for the same thing (0…1): rows and titles
    /// rotate by day, not by launch. FNV-1a, since Swift's hash changes
    /// every launch.
    static func jitter(_ parts: String...) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Double(hash % 10_000) / 10_000
    }

    // MARK: Traits

    /// A trait's weight in a match, by its family: genre, language, keyword,
    /// network, studio, country, decade.
    static func weight(_ feature: String) -> Double {
        switch feature.first {
        case "g": return 1.0
        case "l": return 0.9
        case "k": return 0.7
        case "n": return 0.6
        case "c": return 0.5
        case "o": return 0.4
        case "d": return 0.3
        default: return 0
        }
    }

    /// TMDB's show genres as the film genres they stand for (Sci-Fi &
    /// Fantasy: both), so a film and a show share a taste.
    static func genre(_ id: Int) -> [String] {
        switch id {
        case 10759: return ["g:28", "g:12"]
        case 10765: return ["g:878", "g:14"]
        case 10768: return ["g:10752"]
        default: return ["g:\(id)"]
        }
    }

    static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance", 878: "Science Fiction",
        10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western", 10762: "Kids",
        10763: "News", 10764: "Reality", 10766: "Soap", 10767: "Talk",
    ]

    static func features(_ traits: Traits) -> Set<String> {
        var out = Set<String>()
        for id in traits.genres { out.formUnion(genre(id)) }
        for id in traits.keywords.prefix(20) { out.insert("k:\(id)") }
        for id in traits.companies.prefix(3) { out.insert("c:\(id)") }
        for id in traits.networks.prefix(2) { out.insert("n:\(id)") }
        if let language = traits.language { out.insert("l:\(language)") }
        for country in traits.countries.prefix(2) { out.insert("o:\(country)") }
        if let year = traits.year { out.insert("d:\(year / 10 * 10)") }
        return out
    }

    static func label(_ feature: String, _ taste: Taste) -> String {
        let value = String(feature.dropFirst(2))
        switch feature.first {
        case "g": return genreNames[Int(value) ?? 0] ?? feature
        case "l": return Locale.current.localizedString(forLanguageCode: value) ?? value
        case "o": return Locale.current.localizedString(forRegionCode: value) ?? value
        case "d": return "The \(value)s"
        default: return taste.labels[feature].map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? feature
        }
    }

    // MARK: Taste

    struct Taste: Sendable {
        /// Each trait's share of your watching, weighed (0…1).
        var shares: [String: Double] = [:]
        /// Films' share of it.
        var movieShare = 0.5
        var titles = 0
        var labels: [String: String] = [:]
        /// Each title's traits with its say (summing to 1): for rows that
        /// leave something out (Japanese dramas, not anime).
        var watched: [(features: Set<String>, weight: Double)] = []
        var isEmpty: Bool { titles == 0 }

        /// The share of your watching meeting every condition (any of its
        /// traits) and with none of `none`.
        func share(_ conditions: [[String]], none: [String]) -> Double {
            watched.reduce(0) { sum, title in
                conditions.contains { title.features.isDisjoint(with: $0) }
                    || !title.features.isDisjoint(with: none) ? sum : sum + title.weight
            }
        }
    }

    /// A title you watched, with its say in the taste and its traits.
    struct Known: Sendable {
        let watch: Watch
        let weight: Double
        let tmdbID: Int
        let isMovie: Bool
        let traits: Traits
    }

    private struct KnownBox: Sendable { let known: Known? }

    /// The titles a taste is read from, at most (the weightiest).
    static let tasteTitles = 60

    /// How much a title says about you: a film watched counts fully, a show
    /// more with every episode (full at 10), started or saved a little;
    /// halved every 120 days, never under a fifth (old favourites still count).
    static func engagement(_ watch: Watch, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(watch.last)) / 86_400
        return amount(watch) * max(0.2, pow(0.5, days / 120))
    }

    /// How much of a title you watched, however long ago.
    static func amount(_ watch: Watch) -> Double {
        if watch.type == "movie" { return watch.watched > 0 ? 1 : watch.started ? 0.45 : 0.3 }
        if watch.watched > 0 { return 0.35 + 0.65 * Double(min(watch.watched, 10)) / 10 }
        return watch.started ? 0.4 : 0.3
    }

    static func known(_ watches: [Watch], now: Date) async -> [Known] {
        let weighed = watches.map { ($0, engagement($0, now: now)) }
            .sorted { $0.1 > $1.1 }
            .prefix(tasteTitles)
        let boxes = await boundedConcurrentMap(Array(weighed), limit: 8) { pair -> KnownBox in
            guard let found = await TMDBService.cueTraits(imdbID: pair.0.id, type: pair.0.type) else {
                return KnownBox(known: nil)
            }
            return KnownBox(known: Known(watch: pair.0, weight: pair.1, tmdbID: found.tmdbID,
                                         isMovie: found.isMovie, traits: found.traits))
        }
        return boxes.compactMap(\.known)
    }

    static func taste(_ known: [Known]) -> Taste {
        var taste = Taste()
        let total = known.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return taste }
        var movies = 0.0
        for title in known {
            let features = features(title.traits)
            for feature in features { taste.shares[feature, default: 0] += title.weight / total }
            taste.watched.append((features, title.weight / total))
            if title.isMovie { movies += title.weight }
            taste.labels.merge(title.traits.labels) { old, _ in old }
        }
        taste.movieShare = movies / total
        taste.titles = known.count
        return taste
    }

    /// The taste read against what's popular now: a trait counts for more
    /// where it's rarer there (anime says more about you than drama).
    struct Model: Sendable {
        let taste: Taste
        let base: [String: Double]
        let poolSize: Double
        let tasteNorm: Double

        init(taste: Taste, pool: [Title]) {
            var counts: [String: Double] = [:]
            for title in pool { for feature in features(title.traits) { counts[feature, default: 0] += 1 } }
            let size = Double(max(pool.count, 1))
            let base = counts.mapValues { $0 / size }
            self.taste = taste
            self.base = base
            self.poolSize = size
            var norm = 0.0
            for (feature, share) in taste.shares {
                let x = share * CueRows.weight(feature) * Self.idf(feature, base: base, size: size)
                norm += x * x
            }
            tasteNorm = norm.squareRoot()
        }

        static func idf(_ feature: String, base: [String: Double], size: Double) -> Double {
            log((size + 1) / ((base[feature] ?? 0) * size + 1)) + 1
        }

        func idf(_ feature: String) -> Double { Self.idf(feature, base: base, size: poolSize) }

        /// How much a trait is yours: its share, more where it's rarer than
        /// in what's popular (at most twice).
        func pull(_ feature: String) -> Double {
            let share = taste.shares[feature] ?? 0
            let lift = share / max(base[feature] ?? 0, 0.03)
            return share * min(lift, 4).squareRoot()
        }

        /// How well a title matches the taste (a cosine), leaning to films or
        /// shows as you do.
        func affinity(_ title: Title) -> Double {
            guard !taste.isEmpty, tasteNorm > 0 else { return 0 }
            var dot = 0.0
            var norm = 0.0
            for feature in features(title.traits) {
                let x = CueRows.weight(feature) * idf(feature)
                norm += x * x
                dot += (taste.shares[feature] ?? 0) * x * x
            }
            guard norm > 0 else { return 0 }
            let media = title.isMovie ? taste.movieShare : 1 - taste.movieShare
            return dot / (tasteNorm * norm.squareRoot()) * (0.6 + 0.8 * media)
        }
    }

    /// TMDB's rating, steadied by its votes (few votes lean to 6.5), as 0…1.
    static func quality(_ traits: Traits) -> Double {
        let votes = Double(traits.votes)
        let steady = (votes / (votes + 400)) * traits.rating + (400 / (votes + 400)) * 6.5
        return min(max((steady - 5.5) / 3, 0), 1)
    }

    // MARK: The catalogue

    struct Recipe: Sendable {
        enum Media: Sendable { case movie, series, both }
        let id: String
        let title: String
        let media: Media
        /// TMDB's discover query for films and for shows.
        let movie: [String: String]?
        let tv: [String: String]?
        /// Rows of a kind: kept apart, at most two a tab.
        let group: String
        /// For a row about no trait (acclaimed, new, short): how well it
        /// suits anyone, 0…1.
        let broad: Double
        /// In season (Christmas, Halloween…): lifted while it lasts, and why.
        var season: String? = nil

        /// What the row leaves out, as traits.
        var excluded: [String] {
            var out: [String] = []
            for query in [movie, tv].compactMap({ $0 }) {
                for part in (query["without_genres"] ?? "").split(whereSeparator: { $0 == "," || $0 == "|" }) {
                    out += Int(part).map(CueRows.genre) ?? []
                }
                for part in (query["without_keywords"] ?? "").split(whereSeparator: { $0 == "," || $0 == "|" }) {
                    out.append("k:\(part)")
                }
            }
            return out
        }

        /// What the row is about, as traits: each list a condition met by
        /// any of its traits.
        var about: [[String]] {
            var out: [[String]] = []
            for (query, isMovie) in [(movie, true), (tv, false)] {
                guard let query else { continue }
                for condition in Self.conditions(query, isMovie: isMovie) where !out.contains(condition) {
                    out.append(condition)
                }
            }
            return out
        }

        static func conditions(_ query: [String: String], isMovie: Bool) -> [[String]] {
            var out: [[String]] = []
            func split(_ key: String, _ make: (String) -> [String]) {
                guard let value = query[key] else { return }
                for part in value.split(separator: ",") {
                    out.append(part.split(separator: "|").flatMap { make(String($0)) })
                }
            }
            split("with_genres") { Int($0).map(CueRows.genre) ?? [] }
            split("with_keywords") { ["k:\($0)"] }
            split("with_original_language") { ["l:\($0)"] }
            split("with_origin_country") { ["o:\($0)"] }
            split("with_companies") { ["c:\($0)"] }
            split("with_networks") { ["n:\($0)"] }
            let from = query["primary_release_date.gte"] ?? query["first_air_date.gte"]
            let to = query["primary_release_date.lte"] ?? query["first_air_date.lte"]
            if let from = from.flatMap({ Int($0.prefix(4)) }), let to = to.flatMap({ Int($0.prefix(4)) }),
               from / 10 == to / 10, to - from >= 5 {
                out.append(["d:\(from / 10 * 10)"])
            }
            return out
        }
    }

    private static func film(_ id: String, _ title: String, _ group: String, broad: Double = 0,
                             _ query: [String: String]) -> Recipe {
        Recipe(id: id, title: title, media: .movie, movie: query, tv: nil, group: group, broad: broad)
    }

    private static func show(_ id: String, _ title: String, _ group: String, broad: Double = 0,
                             _ query: [String: String]) -> Recipe {
        Recipe(id: id, title: title, media: .series, movie: nil, tv: query, group: group, broad: broad)
    }

    private static func both(_ id: String, _ title: String, _ group: String, broad: Double = 0,
                             movie: [String: String], tv: [String: String]) -> Recipe {
        Recipe(id: id, title: title, media: .both, movie: movie, tv: tv, group: group, broad: broad)
    }

    /// A row about a keyword (or several, any of them), films and shows.
    private static func keyword(_ id: String, _ title: String, _ group: String, _ keywords: String,
                                media: Recipe.Media = .both) -> Recipe {
        let query = ["with_keywords": keywords]
        switch media {
        case .movie: return film(id, title, group, query)
        case .series: return show(id, title, group, query)
        case .both: return both(id, title, group, movie: query, tv: query)
        }
    }

    private static func genres(_ ids: String) -> [String: String] { ["with_genres": ids] }

    private static func date(_ date: Date) -> String { dayKey(date) }

    /// Every row Cue can make beyond the fixed ones (trending, cinemas,
    /// services, "Because you watched", top picks). Keyword, studio and
    /// network ids checked against TMDB (2026-11-11).
    static func catalogue(now: Date) -> [Recipe] {
        let days = 86_400.0
        let recent = date(now.addingTimeInterval(-90 * days))
        let recentShows = date(now.addingTimeInterval(-120 * days))
        let today = date(now)
        func years(_ from: Int, _ to: Int, tv: Bool = false) -> [String: String] {
            tv ? ["first_air_date.gte": "\(from)-01-01", "first_air_date.lte": "\(to)-12-31"]
               : ["primary_release_date.gte": "\(from)-01-01", "primary_release_date.lte": "\(to)-12-31",
                  "vote_count.gte": "500"]
        }
        let japanese = ["with_original_language": "ja"]
        return [
            // Genres
            film("action.films", "Action Movies", "action", genres("28")),
            show("action.shows", "Action & Adventure Series", "action", genres("10759")),
            film("adventure", "Adventure Movies", "adventure", genres("12")),
            film("comedy.films", "Comedies", "comedy", genres("35")),
            show("comedy.shows", "Comedy Series", "comedy", genres("35")),
            film("crime.films", "Crime Movies", "crime", genres("80")),
            show("crime.shows", "Crime Series", "crime", genres("80")),
            film("thrillers", "Thrillers", "thriller", genres("53")),
            film("horror", "Horror Movies", "horror", genres("27")),
            film("scifi.films", "Sci-Fi Movies", "scifi", genres("878")),
            show("scifi.shows", "Sci-Fi & Fantasy Series", "scifi", genres("10765")),
            film("fantasy.films", "Fantasy Movies", "fantasy", genres("14")),
            film("romance", "Romantic Movies", "romance", genres("10749")),
            film("romcoms", "Romantic Comedies", "romance", genres("10749,35")),
            film("animation.films", "Animated Movies", "animation", genres("16") + ["without_keywords": "210024"]),
            show("animation.adult", "Animated Series for Grown-Ups", "animation",
                 genres("16") + ["without_genres": "10762,10751", "with_original_language": "en"]),
            film("family.films", "Family Movies", "family", genres("10751")),
            show("kids.shows", "Kids' Shows", "family", genres("10762")),
            film("docs.films", "Documentaries", "docs", genres("99") + ["vote_count.gte": "60"]),
            show("docs.shows", "Docuseries", "docs", genres("99") + ["vote_count.gte": "20"]),
            film("mystery.films", "Mystery Movies", "mystery", genres("9648")),
            show("mystery.shows", "Mystery Series", "mystery", genres("9648")),
            film("war.films", "War Movies", "war", genres("10752")),
            show("war.shows", "War & Politics Series", "war", genres("10768")),
            both("westerns", "Westerns", "western", movie: genres("37"), tv: genres("37")),
            film("history.films", "Historical Movies", "history", genres("36")),
            film("music.films", "Music Movies", "music", genres("10402")),
            show("reality", "Reality TV", "reality", genres("10764") + ["vote_count.gte": "10"]),
            film("drama.films", "Dramas", "drama", genres("18")),
            show("drama.shows", "Drama Series", "drama", genres("18")),
            film("actioncomedies", "Action Comedies", "action", genres("28,35")),
            film("scifithrillers", "Sci-Fi Thrillers", "scifi", genres("878,53")),
            film("horrorcomedies", "Horror Comedies", "horror", genres("27,35")),
            film("crimethrillers", "Crime Thrillers", "crime", genres("80,53")),
            show("crimedramas", "Crime Dramas", "crime", genres("80,18")),
            film("animatedadventures", "Animated Family Adventures", "family", genres("16,10751,12")),
            film("fantasyadventures", "Fantasy Adventures", "fantasy", genres("14,12")),
            film("mysterythrillers", "Mystery Thrillers", "mystery", genres("9648,53")),

            // Anime
            show("anime.shows", "Anime Series", "anime", genres("16") + japanese),
            film("anime.films", "Anime Movies", "anime", genres("16") + japanese + ["vote_count.gte": "80"]),
            keyword("isekai", "Isekai", "anime", "237451", media: .series),
            keyword("shounen", "Shōnen Anime", "anime", "207826", media: .series),
            keyword("seinen", "Seinen Anime", "anime", "195668", media: .series),
            keyword("shoujo", "Shōjo Anime", "anime", "206437", media: .series),
            keyword("mecha", "Mecha", "anime", "10046"),
            show("sliceoflife", "Slice of Life", "anime", ["with_keywords": "9914"] + japanese),
            show("anime.action", "Action Anime", "anime", genres("16,10759") + japanese),
            show("anime.fantasy", "Fantasy Anime", "anime", genres("16,10765") + japanese),
            show("anime.comedy", "Comedy Anime", "anime", genres("16,35") + japanese),
            show("anime.mystery", "Anime Mysteries", "anime", genres("16,9648") + japanese),
            keyword("iyashikei", "Iyashikei: Gentle Anime", "anime", "291483", media: .series),

            // Themes
            keyword("timetravel", "Time Travel", "scifi.k", "4379"),
            keyword("heists", "Heists", "crime.k", "10051", media: .movie),
            keyword("truestory", "Based on a True Story", "true", "9672"),
            keyword("books", "Based on a Book", "book", "818"),
            keyword("superheroes", "Superheroes", "superhero", "9715"),
            keyword("zombies", "Zombies", "horror.k", "12377"),
            keyword("vampires", "Vampires", "horror.k", "3133"),
            keyword("space", "Set in Space", "scifi.k", "9882"),
            keyword("aliens", "Aliens", "scifi.k", "9951"),
            keyword("dystopia", "Dystopian Futures", "scifi.k", "4565"),
            keyword("apocalypse", "After the Apocalypse", "scifi.k", "4458|359337|12332"),
            keyword("survival", "Survival Stories", "survival", "10349"),
            keyword("serialkillers", "Serial Killers", "crime.k", "10714"),
            keyword("spies", "Spies", "spy", "470|383851"),
            keyword("martialarts", "Martial Arts", "action.k", "779", media: .movie),
            keyword("revenge", "Revenge", "action.k", "9748", media: .movie),
            keyword("comingofage", "Coming of Age", "youth", "10683"),
            keyword("roadtrips", "Road Trips", "adventure.k", "7312", media: .movie),
            keyword("twists", "Twist Endings", "thriller.k", "326438", media: .movie),
            keyword("cyberpunk", "Cyberpunk", "scifi.k", "12190"),
            keyword("ai", "Artificial Intelligence", "scifi.k", "310"),
            keyword("robots", "Robots", "scifi.k", "14544"),
            keyword("dinosaurs", "Dinosaurs", "creature", "12616", media: .movie),
            keyword("sharks", "Sharks", "creature", "15097", media: .movie),
            keyword("monsters", "Monsters", "creature", "1299|11100|161791", media: .movie),
            keyword("ghosts", "Ghost Stories", "horror.k", "162846"),
            keyword("haunted", "Haunted Houses", "horror.k", "3358", media: .movie),
            keyword("witches", "Witches", "fantasy.k", "616"),
            keyword("magic", "Magic", "fantasy.k", "2343"),
            keyword("dragons", "Dragons", "fantasy.k", "12554"),
            keyword("pirates", "Pirates", "adventure.k", "12988"),
            keyword("samurai", "Samurai", "action.k", "1462"),
            keyword("gangsters", "Gangsters", "crime.k", "3149|10391", media: .movie),
            keyword("organisedcrime", "Organised Crime", "crime.k", "10291|10391", media: .series),
            keyword("courtroom", "Courtroom Dramas", "legal", "33519"),
            keyword("lawyers", "Legal Dramas", "legal", "10909", media: .series),
            keyword("hospital", "Medical Dramas", "medical", "11612", media: .series),
            keyword("cops", "Cops", "crime.k", "6149", media: .series),
            keyword("detectives", "Detectives", "crime.k", "703"),
            keyword("sports", "Sports Stories", "sports", "333328"),
            keyword("boxing", "Boxing", "sports", "209476", media: .movie),
            keyword("racing", "Racing", "sports", "830", media: .movie),
            keyword("cooking", "Cooking", "food", "1918|18293", media: .series),
            keyword("musicals", "Musicals", "music", "4344", media: .movie),
            keyword("videogames", "Based on Video Games", "adaptation", "41645"),
            keyword("comics", "Based on Comics", "adaptation", "9717"),
            keyword("fairytales", "Fairy Tales", "fantasy.k", "3205", media: .movie),
            keyword("mythology", "Myths & Legends", "fantasy.k", "2035"),
            keyword("rome", "Ancient Rome", "history.k", "5049"),
            keyword("ww2", "World War II", "war.k", "1956"),
            keyword("coldwar", "The Cold War", "war.k", "2106"),
            keyword("smalltowns", "Small Towns", "place", "1415"),
            keyword("conspiracies", "Conspiracies", "thriller.k", "10410"),
            keyword("cults", "Cults", "thriller.k", "6158"),
            keyword("hackers", "Hackers", "thriller.k", "2157"),
            keyword("prison", "Prison", "crime.k", "378"),
            keyword("disasters", "Disasters", "action.k", "10617", media: .movie),
            keyword("foundfootage", "Found Footage", "horror.k", "163053", media: .movie),
            keyword("slashers", "Slashers", "horror.k", "12339", media: .movie),
            keyword("folkhorror", "Folk Horror", "horror.k", "209568", media: .movie),
            keyword("supernatural", "Supernatural", "horror.k", "6152"),
            keyword("parallelworlds", "Parallel Worlds", "scifi.k", "33465|336874"),
            keyword("timeloops", "Time Loops", "scifi.k", "10854"),
            keyword("satire", "Satire", "comedy.k", "8201"),
            keyword("parodies", "Parodies", "comedy.k", "9755", media: .movie),
            keyword("mockumentaries", "Mockumentaries", "comedy.k", "11800"),
            keyword("sitcoms", "Sitcoms", "comedy.k", "193171", media: .series),
            keyword("darkcomedies", "Dark Comedies", "comedy.k", "10123"),
            keyword("workplace", "Workplace Comedies", "comedy.k", "210605", media: .series),
            film("standup", "Stand-Up Comedy", "comedy.k", ["with_keywords": "9716", "vote_count.gte": "20"]),
            keyword("psychological", "Psychological Thrillers", "thriller.k", "12565"),
            keyword("political", "Political Thrillers", "thriller.k", "209817"),
            keyword("truecrime", "True Crime", "true", "33722"),
            keyword("biopics", "Biopics", "true", "5565", media: .movie),
            keyword("nature", "The Natural World", "docs", "18330"),
            keyword("spaceoperas", "Space Operas", "scifi.k", "161176"),
            keyword("swordsorcery", "Sword & Sorcery", "fantasy.k", "234213"),
            keyword("assassins", "Assassins", "action.k", "782", media: .movie),
            keyword("conartists", "Con Artists", "crime.k", "10453"),
            keyword("whodunits", "Whodunits", "mystery.k", "12570|207046"),
            keyword("perioddramas", "Period Dramas", "history.k", "15060"),
            keyword("neonoir", "Neo-Noir", "crime.k", "207268", media: .movie),
            keyword("noir", "Film Noir", "classic", "9807", media: .movie),
            keyword("cosmichorror", "Cosmic Horror", "horror.k", "215959", media: .movie),
            keyword("werewolves", "Werewolves", "horror.k", "12564", media: .movie),
            keyword("possession", "Possessions & Exorcisms", "horror.k", "2626|9712", media: .movie),
            keyword("bodyhorror", "Body Horror", "horror.k", "283085", media: .movie),
            keyword("vigilantes", "Vigilantes", "action.k", "7002"),
            keyword("cartels", "Cartels", "crime.k", "10175"),
            keyword("undercover", "Undercover", "crime.k", "1568"),
            keyword("deathgames", "Death Games", "thriller.k", "295702|285633|227620"),
            keyword("virtualworlds", "Virtual Worlds", "scifi.k", "4563"),
            keyword("invasions", "Alien Invasions", "scifi.k", "14909"),
            keyword("anthologies", "Anthologies", "format", "9706", media: .series),
            keyword("friendship", "Friendship", "youth", "6054"),
            keyword("highschool", "High School", "youth", "6270"),
            keyword("families", "Family Stories", "drama.k", "10235"),

            // Languages and countries
            show("kdramas", "Korean Dramas", "world", ["with_original_language": "ko"] + genres("18")),
            film("korean.films", "Korean Movies", "world", ["with_original_language": "ko"]),
            film("japanese.films", "Japanese Movies", "world", japanese + ["without_genres": "16"]),
            show("jdramas", "Japanese Dramas", "world", japanese + genres("18") + ["without_genres": "16"]),
            show("cdramas", "Chinese Dramas", "world", ["with_original_language": "zh"] + genres("18")),
            show("spanish.shows", "Spanish-Language Series", "world", ["with_original_language": "es"]),
            show("latam", "Latin American Series", "world", ["with_origin_country": "MX|AR|CO|BR|CL"]),
            film("french.films", "French Films", "world", ["with_original_language": "fr"]),
            film("italian.films", "Italian Films", "world", ["with_original_language": "it"]),
            show("german.shows", "German Series", "world", ["with_original_language": "de"]),
            show("turkish.shows", "Turkish Series", "world", ["with_original_language": "tr"]),
            film("bollywood", "Bollywood", "world", ["with_original_language": "hi"]),
            film("hkaction", "Hong Kong Action", "world", ["with_original_language": "cn|zh"] + genres("28")),
            show("british.crime", "British Crime Series", "world", ["with_origin_country": "GB"] + genres("80")),
            show("british.comedy", "British Comedies", "world", ["with_origin_country": "GB"] + genres("35")),
            show("nordicnoir", "Nordic Noir", "world", ["with_origin_country": "SE|DK|NO|IS|FI"] + genres("80")),

            // Eras
            film("70s", "'70s Movies", "era", years(1970, 1979)),
            film("80s", "'80s Movies", "era", years(1980, 1989)),
            film("90s", "'90s Movies", "era", years(1990, 1999)),
            film("00s", "2000s Movies", "era", years(2000, 2009)),
            show("90s.sitcoms", "'90s Sitcoms", "era", years(1990, 1999, tv: true) + genres("35")),
            film("classics", "Classics", "classic", broad: 0.3,
                 ["primary_release_date.lte": "1969-12-31", "vote_count.gte": "800", "sort_by": "vote_average.desc"]),

            // For anyone
            film("acclaimed.films", "Critically Acclaimed Movies", "acclaimed", broad: 0.5,
                 ["vote_average.gte": "7.8", "vote_count.gte": "3000", "sort_by": "vote_average.desc"]),
            show("acclaimed.shows", "Critically Acclaimed Series", "acclaimed", broad: 0.5,
                 ["vote_average.gte": "8.2", "vote_count.gte": "800", "sort_by": "vote_average.desc"]),
            show("bingeworthy", "Binge-Worthy", "acclaimed", broad: 0.45,
                 ["vote_average.gte": "8", "vote_count.gte": "1500"]),
            film("gems.films", "Hidden Gems", "gems", broad: 0.45,
                 ["vote_average.gte": "7.2", "vote_count.gte": "200", "vote_count.lte": "1500"]),
            show("gems.shows", "Hidden Gem Series", "gems", broad: 0.45,
                 ["vote_average.gte": "7.8", "vote_count.gte": "80", "vote_count.lte": "600"]),
            film("short", "Under 90 Minutes", "format", broad: 0.35,
                 ["with_runtime.lte": "90", "with_runtime.gte": "60", "vote_average.gte": "6.8"]),
            film("epics", "Epics", "format", broad: 0.3, ["with_runtime.gte": "150", "vote_average.gte": "7"]),
            show("limited", "Limited Series", "format", broad: 0.4, ["with_type": "2"]),
            film("new.films", "New Releases", "new", broad: 0.5,
                 ["primary_release_date.gte": recent, "primary_release_date.lte": today, "vote_count.gte": "50"]),
            show("new.shows", "New Series", "new", broad: 0.5,
                 ["first_air_date.gte": recentShows, "first_air_date.lte": today, "vote_count.gte": "10"]),
            film("blockbusters", "Blockbusters", "big", broad: 0.35,
                 ["vote_count.gte": "8000", "sort_by": "revenue.desc"]),

            // Studios and networks
            film("a24", "A24", "studio", ["with_companies": "41077"]),
            film("ghibli", "Studio Ghibli", "studio", ["with_companies": "10342", "vote_count.gte": "100"]),
            film("pixar", "Pixar", "studio", ["with_companies": "3"]),
            both("marvel", "Marvel Studios", "studio", movie: ["with_companies": "420"], tv: ["with_companies": "420"]),
            both("dc", "DC", "studio", movie: ["with_companies": "128064|9993"], tv: ["with_companies": "9993"]),
            both("lucasfilm", "Lucasfilm", "studio", movie: ["with_companies": "1"], tv: ["with_companies": "1"]),
            film("blumhouse", "Blumhouse Horror", "studio", ["with_companies": "3172"]),
            film("dreamworks", "DreamWorks Animation", "studio", ["with_companies": "521"]),
            film("neon", "NEON", "studio", ["with_companies": "90733", "vote_count.gte": "100"]),
            film("stopmotion", "Stop-Motion: LAIKA & Aardman", "studio", ["with_companies": "11537|297", "vote_count.gte": "100"]),
            film("disney", "Disney", "studio", ["with_companies": "2"]),
            show("hbo", "HBO Originals", "network", ["with_networks": "49"]),
            show("fx", "FX Originals", "network", ["with_networks": "88"]),
            show("amc", "AMC Originals", "network", ["with_networks": "174"]),
            show("britishtv", "From British TV", "network", ["with_networks": "4|332|26|9"]),
            show("adultswim", "Adult Swim", "network", ["with_networks": "80"]),
            show("apple", "Apple Originals", "network", ["with_networks": "2552"]),
            show("netflix", "Netflix Originals", "network", ["with_networks": "213"]),
            show("showtime", "Showtime", "network", ["with_networks": "67"]),

            // This anime season: anime with an episode out since the season
            // began (January, April, July, October), new or returning.
            show("anime.season", "This Anime Season", "season.anime",
                 genres("16") + japanese + ["air_date.gte": date(animeSeasonStart(now)),
                                            "air_date.lte": date(now.addingTimeInterval(7 * days)),
                                            "vote_count.gte": "5"]),
        ] + seasonal(now: now)
    }

    /// The first day of the anime season `now` is in.
    static func animeSeasonStart(_ now: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month], from: now)
        let month = ((parts.month ?? 1) - 1) / 3 * 3 + 1
        return calendar.date(from: DateComponents(year: parts.year, month: month, day: 1)) ?? now
    }

    /// Rows for the time of year, only while it lasts (from, to: month and
    /// day, inclusive; across the new year where `from` is later).
    static func seasonal(now: Date) -> [Recipe] {
        let parts = Calendar.current.dateComponents([.month, .day], from: now)
        let today = (parts.month ?? 1) * 100 + (parts.day ?? 1)
        func during(_ from: Int, _ to: Int) -> Bool {
            from <= to ? (from...to).contains(today) : today >= from || today <= to
        }
        var out: [Recipe] = []
        func add(_ from: Int, _ to: Int, _ season: String, _ recipe: Recipe) {
            guard during(from, to) else { return }
            var recipe = recipe
            recipe.season = season
            out.append(recipe)
        }
        add(1001, 1031, "Halloween", keyword("halloween", "Halloween", "season", "3335|9694"))
        add(1001, 1031, "Halloween", film("halloween.family", "Spooky, Not Scary", "season",
                                          ["with_keywords": "3335|162846|616", "with_genres": "10751|16"]))
        add(1125, 1226, "Christmas", keyword("christmas", "Christmas Movies", "season", "207317|1991|272288", media: .movie))
        add(1125, 1226, "Christmas", film("christmas.family", "Christmas for the Family", "season",
                                          ["with_keywords": "207317|1991", "with_genres": "10751"]))
        add(1215, 1226, "Christmas", show("christmas.shows", "Christmas Episodes & Specials", "season",
                                          ["with_keywords": "207317|1991", "vote_count.gte": "5"]))
        add(1227, 101, "New Year", film("newyear", "New Year's Eve", "season", ["with_keywords": "613", "vote_count.gte": "30"]))
        add(1115, 1130, "Thanksgiving", film("thanksgiving", "Thanksgiving", "season", ["with_keywords": "4543", "vote_count.gte": "30"]))
        add(201, 214, "Valentine's Day", film("valentines", "Date Night", "season",
                                              ["with_genres": "10749", "vote_average.gte": "7", "vote_count.gte": "500"]))
        add(102, 228, "winter", keyword("winter", "Snowed In", "season", "10794|1442", media: .movie))
        add(601, 630, "Pride Month", keyword("pride", "Pride", "season", "158718"))
        add(615, 831, "summer", keyword("summer", "Summer Movies", "season", "13088|14714|966", media: .movie))
        add(615, 831, "summer", film("summer.blockbusters", "Summer Blockbusters", "season",
                                     ["sort_by": "revenue.desc", "vote_count.gte": "3000", "with_genres": "28|12"]))
        return out
    }

    // MARK: Lists

    /// One list's wait at most, as a catalog's (`HomeViewModel.catalogWait`).
    static let listWait: Double = 8

    /// One list's titles, at most `listWait`.
    private static func list(_ path: String, _ query: [String: String] = [:], isMovie: Bool) async -> [Title] {
        (try? await withDeadline(listWait) {
            await TMDBService.cueList(path, query: query, isMovie: isMovie)
        }) ?? []
    }

    /// Films and shows taken in turn.
    private static func interleave(_ a: [Title], _ b: [Title]) -> [Title] {
        var out: [Title] = []
        for index in 0..<max(a.count, b.count) {
            if index < a.count { out.append(a[index]) }
            if index < b.count { out.append(b[index]) }
        }
        return out
    }

    private static func discover(_ query: [String: String], isMovie: Bool, page: Int) async -> [Title] {
        var full = isMovie
            ? ["sort_by": "popularity.desc", "vote_count.gte": "150", "include_adult": "false"]
            : ["sort_by": "popularity.desc", "vote_count.gte": "50", "without_genres": "10763,10767",
               "include_adult": "false"]
        full.merge(query) { $1 }
        if page > 1 { full["page"] = String(page) }
        return await list(isMovie ? "/discover/movie" : "/discover/tv", full, isMovie: isMovie)
    }

    /// A recipe's titles: TMDB's pages until `fetchUntil` you haven't seen
    /// (or a page comes back short: the list's end).
    private static func titles(of recipe: Recipe, seen: Set<String>) async -> [Title] {
        func page(_ number: Int) async -> (titles: [Title], full: Bool) {
            async let films: [Title] = recipe.movie == nil ? [] : discover(recipe.movie!, isMovie: true, page: number)
            async let shows: [Title] = recipe.tv == nil ? [] : discover(recipe.tv!, isMovie: false, page: number)
            let (a, b) = (await films, await shows)
            // (A page loses a few to missing pictures or ids: "full" is near 20.)
            return (interleave(a, b), max(a.count, b.count) >= 15)
        }
        var all: [Title] = []
        for number in 1...maxPages {
            let next = await page(number)
            all += next.titles
            if !next.full || all.filter({ !seen.contains($0.item.id) }).count >= fetchUntil { break }
        }
        return all
    }

    /// The rows every day has.
    private struct Fixed: Sendable {
        var trendingAll: [Title] = []
        var trendingMovies: [Title] = []
        var trendingShows: [Title] = []
        var cinemas: [Title] = []
        var comingSoon: [Title] = []
        var onTheAir: [Title] = []
        var airingToday: [Title] = []
        var popularMovies: [Title] = []
        var popularShows: [Title] = []
        var topMovies: [Title] = []
        var topShows: [Title] = []

        /// What's popular now: what a taste is read against.
        var pool: [Title] { trendingAll + trendingMovies + trendingShows + popularMovies + popularShows + topMovies + topShows }
        var all: [Title] { pool + cinemas + comingSoon + onTheAir + airingToday }
    }

    private static func fixed(region: String) async -> Fixed {
        async let trendingAll = list("/trending/all/day", isMovie: true)
        async let trendingMovies = list("/trending/movie/week", isMovie: true)
        async let trendingShows = list("/trending/tv/week", isMovie: false)
        async let cinemas = list("/movie/now_playing", ["region": region], isMovie: true)
        async let comingSoon = list("/movie/upcoming", ["region": region], isMovie: true)
        async let onTheAir = list("/tv/on_the_air", isMovie: false)
        async let airingToday = list("/tv/airing_today", isMovie: false)
        async let popularMovies = list("/movie/popular", ["region": region], isMovie: true)
        async let popularShows = list("/tv/popular", isMovie: false)
        async let topMovies = list("/movie/top_rated", isMovie: true)
        async let topShows = list("/tv/top_rated", isMovie: false)
        return Fixed(trendingAll: await trendingAll, trendingMovies: await trendingMovies,
                     trendingShows: await trendingShows, cinemas: await cinemas, comingSoon: await comingSoon,
                     onTheAir: await onTheAir, airingToday: await airingToday,
                     popularMovies: await popularMovies, popularShows: await popularShows,
                     topMovies: await topMovies, topShows: await topShows)
    }

    private struct Service: Sendable {
        let provider: TMDBService.WatchProvider
        let films: [Title]
        let shows: [Title]
    }

    /// The country's subscription services with enough on them, most
    /// important first.
    private static func services(count: Int, region: String) async -> [Service] {
        async let movieSide = TMDBService.watchProviders(isMovie: true, region: region)
        async let showSide = TMDBService.watchProviders(isMovie: false, region: region)
        var seen = Set<Int>()
        // (Ad tiers and channels inside another store repeat a service.)
        let candidates = (await movieSide + showSide).filter { provider in
            let name = provider.name.lowercased()
            return !name.contains("with ads") && !name.contains("channel") && seen.insert(provider.id).inserted
        }.prefix(8)
        let filled = await boundedConcurrentMap(Array(candidates), limit: 8) { provider -> Service in
            let query = ["with_watch_providers": String(provider.id), "watch_region": region,
                         "with_watch_monetization_types": "flatrate"]
            async let films = discover(query, isMovie: true, page: 1)
            async let shows = discover(query, isMovie: false, page: 1)
            return Service(provider: provider, films: await films, shows: await shows)
        }
        return Array(filled.filter { $0.films.count + $0.shows.count >= 12 }.prefix(count))
    }

    // MARK: Building

    /// One tab's rows, made in order: a title in two rows already stays
    /// out of the next, one in one row goes further back.
    private struct Layout {
        let tab: String
        let model: Model
        let seen: Set<String>
        /// Shows you started and left: allowed, further back.
        let left: Set<String>
        let passes: Passes
        let day: String
        var rows: [Row] = []
        var why: [Why] = []
        var used: [String: Int] = [:]
        var themed: [String] = []

        /// Adds a row if enough is left. `fresh`: what you've seen stays
        /// out. `keepOrder`: the list's order is its point (trending, new);
        /// else the best for you first, then the better and more popular.
        @discardableResult
        mutating func add(_ id: String, _ title: String, _ titles: [Title], fresh: Bool = true,
                          keepOrder: Bool = false, minimum: Int = CueRows.minimumTitles,
                          own: Bool = false, reason: String) -> Bool {
            var unique = Set<String>()
            let candidates = titles.filter {
                unique.insert($0.item.id).inserted
                    && !(fresh && (seen.contains($0.item.id) || passes.isOut($0.item.id, day: day)))
            }
            var ordered = candidates
            if !keepOrder {
                let affinities = candidates.map(model.affinity)
                let top = max(affinities.max() ?? 0, 0.0001)
                let count = Double(max(candidates.count, 1))
                let scored = candidates.enumerated().map { index, title -> (Title, Double) in
                    let score = 0.5 * affinities[index] / top
                        + 0.25 * CueRows.quality(title.traits)
                        + 0.25 * (1 - Double(index) / count)
                        + 0.15 * CueRows.jitter(day, id, title.item.id)
                        - 0.35 * Double(used[title.item.id] ?? 0)
                        - 0.12 * Double(passes.count(title.item.id))
                        - (left.contains(title.item.id) ? 0.3 : 0)
                    return (title, score)
                }
                ordered = scored.sorted { $0.1 > $1.1 }.map(\.0)
            }
            // (Your own rows show all of theirs: a title elsewhere twice is
            // still one you left or finished.)
            let shown = ordered.filter { own || (used[$0.item.id] ?? 0) < 2 }.prefix(CueRows.rowLength)
            guard shown.count >= minimum else { return false }
            for title in shown { used[title.item.id, default: 0] += 1 }
            rows.append(Row(id: "cue.\(tab).\(id)", title: title, tabs: [tab], items: shown.map(\.item)))
            why.append(Why(tab: tab, title: title, reason: reason))
            return true
        }
    }

    /// The best matches for your taste across everything fetched today.
    private static func topPicks(_ pool: [Title], model: Model, seen: Set<String>, passes: Passes, day: String,
                                 isMovie: Bool?) -> [Title] {
        guard !model.taste.isEmpty else { return [] }
        var unique = Set<String>()
        let candidates = pool.filter {
            (isMovie == nil || $0.isMovie == isMovie) && !seen.contains($0.item.id)
                && !passes.isOut($0.item.id, day: day) && unique.insert($0.item.id).inserted
        }
        let top = max(candidates.map(model.affinity).max() ?? 0, 0.0001)
        return candidates
            .map { ($0, 0.75 * model.affinity($0) / top + 0.25 * quality($0.traits)
                        + 0.1 * jitter(day, "picks", $0.item.id) - 0.12 * Double(passes.count($0.item.id))) }
            .sorted { $0.1 > $1.1 }
            .prefix(rowLength)
            .map(\.0)
    }

    /// The catalogue's rows for a tab, best first, at most two of a group.
    private static func choose(_ ranked: [Recipe], count: Int, where keep: (Recipe) -> Bool) -> [Recipe] {
        var groups: [String: Int] = [:]
        var out: [Recipe] = []
        for recipe in ranked where out.count < count && keep(recipe) {
            guard groups[recipe.group, default: 0] < 2 else { continue }
            groups[recipe.group, default: 0] += 1
            out.append(recipe)
        }
        return out
    }

    /// No two rows of a group one after the other, where it can be helped.
    private static func spaced(_ recipes: [Recipe]) -> [Recipe] {
        var left = recipes
        var out: [Recipe] = []
        while !left.isEmpty {
            let index = left.firstIndex { $0.group != out.last?.group } ?? 0
            out.append(left.remove(at: index))
        }
        return out
    }

    private struct Seed: Sendable {
        let known: Known
        let name: String
        let titles: [Title]
    }

    static func build(watches: [Watch], standings full: Standings, seeds: [String], last: Saved?,
                      passes: Passes) async -> Saved {
        let now = Date()
        let day = dayKey(now)
        let region = region
        // Finished or being watched: out of the rows. Left: allowed, further
        // back, and in Pick Back Up.
        let standings = full.states
        let seen = Set(standings.filter { $0.value != .left }.keys)
        let left = Set(standings.filter { $0.value == .left }.keys)
        let byID = Dictionary(watches.map { ($0.id, $0) }) { a, _ in a }
        async let ownTask = own(watches: watches, standings: full, now: now, day: day)
        async let knownTask = known(watches, now: now)
        async let fixedTask = fixed(region: region)
        async let servicesTask = services(count: 3, region: region)
        let known = await knownTask
        let fixed = await fixedTask
        let taste = taste(known)
        let model = Model(taste: taste, pool: fixed.pool)
        let previous = last.map { $0.day == day ? $0.previous : $0.picked } ?? []

        // The catalogue, scored: how much each row is about you, a share of
        // the day's chance, less if it was up yesterday.
        let recipes = catalogue(now: now)
        let relevance = recipes.map { recipe -> (value: Double, because: String?) in
            relevanceOf(recipe, model)
        }
        let topRelevance = max(zip(recipes, relevance).filter { !$0.0.about.isEmpty }.map(\.1.value).max() ?? 0, 0.0001)
        var score: [String: Double] = [:]
        var reason: [String: String] = [:]
        for (recipe, rel) in zip(recipes, relevance) {
            let chance = jitter(day, recipe.id)
            let fit = recipe.about.isEmpty ? recipe.broad : rel.value / topRelevance
            // Rows you go through without looking along sink; rows you
            // explore rise a little.
            let (passed, explored) = passes.row(recipe.id, day: day)
            let habit = 0.06 * Double(min(explored, 2)) - 0.08 * Double(min(passed, 3))
            let inSeason = recipe.season == nil ? 0 : 0.3
            let value = (taste.isEmpty
                ? chance + 0.3 * recipe.broad
                : 0.65 * fit + 0.35 * chance - (previous.contains(recipe.id) ? 0.12 : 0)) + habit + inSeason
            score[recipe.id] = value
            let figure = String(format: "%.2f", value)
            func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
            let habitNote = passed > explored ? ", passed over \(days(passed))"
                : explored > 0 ? ", explored \(days(explored))" : ""
            if let season = recipe.season {
                reason[recipe.id] = "For \(season)\(habitNote) (\(figure))"
            } else if taste.isEmpty {
                reason[recipe.id] = "Today's rotation: no taste yet\(habitNote) (\(figure))"
            } else if let feature = rel.because, (taste.shares[feature] ?? 0) > 0 {
                let share = Int(((taste.shares[feature] ?? 0) * 100).rounded())
                reason[recipe.id] = "\(label(feature, taste)): \(share) % of your watching\(habitNote) (\(figure))"
            } else if recipe.about.isEmpty {
                reason[recipe.id] = "For anyone, in today's rotation\(habitNote) (\(figure))"
            } else {
                reason[recipe.id] = "Something different, in today's rotation\(habitNote) (\(figure))"
            }
        }
        let ranked = recipes.sorted { (score[$0.id] ?? 0) > (score[$1.id] ?? 0) }
        let homeRecipes = choose(ranked, count: 21) { _ in true }
        let movieRecipes = choose(ranked, count: 17) { $0.media == .movie }
        let seriesRecipes = choose(ranked, count: 17) { $0.media == .series }
        var needed: [String: Recipe] = [:]
        for recipe in homeRecipes + movieRecipes + seriesRecipes { needed[recipe.id] = recipe }
        let fetched = Dictionary(uniqueKeysWithValues: await boundedConcurrentMap(Array(needed.values), limit: 4) {
            recipe -> (String, [Title]) in (recipe.id, await titles(of: recipe, seen: seen))
        })

        // "Because you watched": your latest title always, two more of your
        // recent five by the day; the first film and show for their tabs.
        let recent = known.filter { $0.watch.watched > 0 || $0.watch.started }
            .sorted { $0.watch.last > $1.watch.last }
            .prefix(6)
        var chosen = Array(recent.prefix(1))
        chosen += recent.dropFirst().sorted { jitter(day, "seed", $0.watch.id) > jitter(day, "seed", $1.watch.id) }.prefix(2)
        var seedKnown = chosen
        for isMovie in [true, false] where !seedKnown.contains(where: { $0.isMovie == isMovie }) {
            if let first = recent.first(where: { $0.isMovie == isMovie }) { seedKnown.append(first) }
        }
        let seedRows = await boundedConcurrentMap(seedKnown, limit: 4) { known -> Seed in
            let path = known.isMovie ? "/movie/\(known.tmdbID)/recommendations" : "/tv/\(known.tmdbID)/recommendations"
            return Seed(known: known, name: known.traits.name ?? "",
                        titles: await list(path, isMovie: known.isMovie))
        }.filter { !$0.name.isEmpty }
        let services = await servicesTask
        let own = await ownTask

        let pool = fixed.all + fetched.values.flatMap { $0 } + seedRows.flatMap(\.titles)
        let picksReason = "Your best matches among today's \(Set(pool.map(\.item.id)).count) titles"
        let seedReason = "From your recent watching"
        let newReason = "Always here, your shows first"
        let serviceReason = "One of the biggest services in \(Locale.current.localizedString(forRegionCode: region) ?? region)"

        func becauseRow(_ layout: inout Layout, _ seed: Seed?) {
            guard let seed else { return }
            layout.add("because.\(seed.known.watch.id)", "Because You Watched \(seed.name)", seed.titles,
                       reason: seedReason)
        }
        func serviceRow(_ layout: inout Layout, _ index: Int) {
            guard index < services.count else { return }
            let service = services[index]
            let titles: [Title]
            switch layout.tab {
            case "movie": titles = service.films
            case "series": titles = service.shows
            default: titles = interleave(service.films, service.shows)
            }
            layout.add("service.\(service.provider.id)", "Popular on \(service.provider.name)", titles,
                       fresh: false, reason: serviceReason)
        }
        /// The tab's catalogue rows, `count` of them, with the fixed rows
        /// set in among them (`inserts`, by how many catalogue rows come
        /// before).
        func themed(_ layout: inout Layout, _ picks: [Recipe], count: Int,
                    inserts: [(Int, (inout Layout) -> Void)]) {
            var done = 0
            func insert(upTo position: Int) {
                while done < inserts.count, inserts[done].0 <= position {
                    inserts[done].1(&layout)
                    done += 1
                }
            }
            for recipe in spaced(picks) where layout.themed.count < count {
                insert(upTo: layout.themed.count)
                guard let titles = fetched[recipe.id] else { continue }
                if layout.add("r.\(recipe.id)", recipe.title, titles, reason: reason[recipe.id] ?? "") {
                    layout.themed.append(recipe.id)
                }
            }
            insert(upTo: .max)
        }

        /// Shows you started and left, the most watched and latest first.
        func pickBackUp(_ layout: inout Layout) {
            layout.add("pickbackup", "Pick Back Up", own.pickBackUp, fresh: false, keepOrder: true, minimum: minimumOwn, own: true,
                       reason: "Shows you started, untouched for over a month")
        }
        /// Some days (`rewatchChance`): what you finished long ago, for the
        /// season where it fits, else from a year ago, else any.
        func rewatch(_ layout: inout Layout) {
            guard jitter(day, "rewatch") < rewatchChance else { return }
            let tab = layout.tab
            let media: (Title) -> Bool = { title in
                switch tab {
                case "movie": return title.isMovie
                case "series": return !title.isMovie
                default: return true
                }
            }
            func ranked(_ titles: [Title]) -> [Title] {
                titles.filter(media).sorted {
                    func score(_ t: Title) -> Double {
                        amount(byID[t.item.id] ?? Watch(id: "", type: "", last: now)) + 0.3 * quality(t.traits)
                            + 0.3 * jitter(day, "rewatch", t.item.id)
                    }
                    return score($0) > score($1)
                }
            }
            for (season, keywords) in seasonalKeywords(now: now) {
                let titles = ranked(own.rewatch.filter { !Set($0.traits.keywords).isDisjoint(with: keywords) })
                if layout.add("rewatch.season", "\(season.prefix(1).uppercased() + season.dropFirst()) Favourites",
                              titles, fresh: false, keepOrder: true, minimum: minimumOwn, own: true,
                              reason: "For \(season): titles you finished before") { return }
            }
            let yearAgo = ranked(own.rewatch.filter { title in
                let ago = now.timeIntervalSince(byID[title.item.id]?.last ?? now) / 86_400
                return (335...395).contains(ago)
            })
            if jitter(day, "rewatch.year") < 0.5,
               layout.add("rewatch.year", "A Year Ago This Month", yearAgo, fresh: false, keepOrder: true,
                          minimum: minimumOwn, own: true, reason: "What you were watching a year ago") { return }
            layout.add("rewatch", "Watch Again", ranked(own.rewatch), fresh: false, keepOrder: true,
                       minimum: minimumOwn, own: true, reason: "Finished at least \(rewatchAfterDays) days ago, some days")
        }

        let homeSeeds = seedRows.filter { seed in chosen.contains { $0.watch.id == seed.known.watch.id } }
        func seed(_ index: Int) -> Seed? { index < homeSeeds.count ? homeSeeds[index] : nil }

        var home = Layout(tab: "home", model: model, seen: seen, left: left, passes: passes, day: day)
        home.add("picks", "Top Picks for You", topPicks(pool, model: model, seen: seen.union(left), passes: passes, day: day, isMovie: nil),
                 keepOrder: true, reason: picksReason)
        becauseRow(&home, seed(0))
        home.add("trending", "Trending Today", fixed.trendingAll, fresh: false, keepOrder: true,
                 reason: "Always here")
        themed(&home, homeRecipes, count: 15, inserts: [
            (1, { $0.add("ontheair", "New Episodes This Week", own.newEpisodes + fixed.onTheAir, fresh: false,
                         keepOrder: true, reason: newReason) }),
            (2, { serviceRow(&$0, 0) }),
            (3, { pickBackUp(&$0) }),
            (4, { becauseRow(&$0, seed(1)) }),
            (5, { rewatch(&$0) }),
            (6, { serviceRow(&$0, 1) }),
            (8, { becauseRow(&$0, seed(2)) }),
            (10, { serviceRow(&$0, 2) }),
        ])

        var movies = Layout(tab: "movie", model: model, seen: seen, left: left, passes: passes, day: day)
        movies.add("picks", "Top Picks for You", topPicks(pool, model: model, seen: seen.union(left), passes: passes, day: day, isMovie: true),
                   keepOrder: true, reason: picksReason)
        becauseRow(&movies, seedRows.first { $0.known.isMovie })
        movies.add("trending", "Trending Movies", fixed.trendingMovies, fresh: false, keepOrder: true,
                   reason: "Always here")
        movies.add("cinemas", "Now in Cinemas", fixed.cinemas, fresh: false, keepOrder: true, reason: "Always here")
        themed(&movies, movieRecipes, count: 12, inserts: [
            (1, { serviceRow(&$0, 0) }),
            (3, { $0.add("upcoming", "Coming Soon", fixed.comingSoon, fresh: false, keepOrder: true,
                         reason: "Always here") }),
            (5, { $0.add("popular", "Popular Movies", fixed.popularMovies, fresh: false, reason: "Always here") }),
            (6, { rewatch(&$0) }),
            (7, { serviceRow(&$0, 1) }),
            (9, { $0.add("toprated", "Top Rated Movies", fixed.topMovies, fresh: false, reason: "Always here") }),
            (11, { serviceRow(&$0, 2) }),
        ])

        var shows = Layout(tab: "series", model: model, seen: seen, left: left, passes: passes, day: day)
        shows.add("picks", "Top Picks for You", topPicks(pool, model: model, seen: seen.union(left), passes: passes, day: day, isMovie: false),
                  keepOrder: true, reason: picksReason)
        becauseRow(&shows, seedRows.first { !$0.known.isMovie })
        shows.add("trending", "Trending Shows", fixed.trendingShows, fresh: false, keepOrder: true,
                  reason: "Always here")
        shows.add("ontheair", "New Episodes This Week", own.newEpisodes + fixed.onTheAir, fresh: false,
                  keepOrder: true, reason: newReason)
        themed(&shows, seriesRecipes, count: 12, inserts: [
            (1, { serviceRow(&$0, 0) }),
            (2, { pickBackUp(&$0) }),
            (3, { $0.add("airingtoday", "Airing Today", own.airingToday + fixed.airingToday, fresh: false,
                         keepOrder: true, reason: newReason) }),
            (5, { $0.add("popular", "Popular Shows", fixed.popularShows, fresh: false, reason: "Always here") }),
            (6, { rewatch(&$0) }),
            (7, { serviceRow(&$0, 1) }),
            (9, { $0.add("toprated", "Top Rated Shows", fixed.topShows, fresh: false, reason: "Always here") }),
            (11, { serviceRow(&$0, 2) }),
        ])

        let tasteLines = taste.shares.keys
            .sorted { model.pull($0) > model.pull($1) }
            .prefix(30)
            .map { TasteLine(label: label($0, taste), share: taste.shares[$0] ?? 0) }
        let layouts = [home, movies, shows]
        return Saved(builtAt: now, seeds: seeds, rows: layouts.flatMap(\.rows), day: day,
                     picked: Array(Set(layouts.flatMap(\.themed))), previous: previous,
                     titles: known.count, taste: tasteLines, why: layouts.flatMap(\.why),
                     passedOver: passes.out(day: day).compactMap { id in pool.first { $0.item.id == id }?.item.name })
    }

    /// How much a row is about you: its traits' pull (each condition its
    /// best trait; the mean and the weakest, halved), leaning to films or
    /// shows as you do. `because`: the trait that pulls most.
    private static func relevanceOf(_ recipe: Recipe, _ model: Model) -> (value: Double, because: String?) {
        let conditions = recipe.about
        var value = recipe.broad
        var because: String?
        if !conditions.isEmpty {
            var pulls: [Double] = []
            var best = -1.0
            for condition in conditions {
                var top = 0.0
                for feature in condition {
                    let pull = model.pull(feature)
                    top = max(top, pull)
                    if pull > best { best = pull; because = feature }
                }
                pulls.append(top)
            }
            value = (pulls.reduce(0, +) / Double(pulls.count) + (pulls.min() ?? 0)) / 2
            // What it leaves out: only the part of your watching it keeps
            // counts (Japanese dramas for an anime watcher: little).
            let excluded = recipe.excluded
            if !excluded.isEmpty {
                let all = model.taste.share(conditions, none: [])
                if all > 0 { value *= model.taste.share(conditions, none: excluded) / all }
            }
        }
        let films = model.taste.movieShare
        switch recipe.media {
        case .movie: value *= 0.5 + films
        case .series: value *= 1.5 - films
        case .both: break
        }
        return (value, because)
    }
}

private func + (lhs: [String: String], rhs: [String: String]) -> [String: String] {
    lhs.merging(rhs) { $1 }
}

// MARK: - Where you are in what you watched

extension CueRows {
    /// A title you watched or started, for the rows: finished (a film
    /// watched, a show caught up) and being watched (Continue Watching, or
    /// an episode in the last 30 days) stay out; left (a show started, then
    /// untouched) is allowed and gets Pick Back Up.
    enum Standing: Sendable { case finished, watching, left }

    struct Standings: Sendable {
        var states: [String: Standing] = [:]
        /// Your shows' latest aired episode (New Episodes, Airing Today).
        var aired: [String: Date] = [:]
    }

    /// Untouched this long, a show you started counts as left (Next Up's
    /// window: it's gone from Continue Watching by then).
    static let leftAfter: TimeInterval = 30 * 24 * 60 * 60
    /// Shows looked up for where you are (their episode lists, the add-ons').
    static let standingShows = 80

    /// A show is measured by the furthest episode watched: a season skipped
    /// behind it doesn't count; only an aired episode after it leaves the
    /// show unfinished.
    @MainActor static func standings(_ history: BillboardPicks.History?) async -> Standings {
        guard let history else { return Standings() }
        let now = Date()
        var out = Standings()
        var shows: [Watch] = []
        for watch in history.watches where watch.watched > 0 || watch.started {
            if watch.type == "movie" {
                out.states[watch.id] = watch.watched > 0 ? .finished : .watching
            } else {
                shows.append(watch)
            }
        }
        let checked = Array(shows.prefix(standingShows))
        let found: [String: (caughtUp: Bool?, aired: Date?)] = await withTaskGroup(
            of: (String, Bool?, Date?).self) { group in
            guard let addonManager = AddonManager.shared else { return [:] }
            for watch in checked {
                group.addTask { @MainActor in
                    let meta = await SeriesEpisodes.fullMeta(
                        for: MetaItem(id: watch.id, type: watch.type, name: watch.id), addonManager: addonManager)
                    let aired = SeriesEpisodes.latestAired(in: meta)?.aired
                    let all = SeriesEpisodes.inPlayOrder(meta).filter { ($0.season ?? 0) > 0 }
                    guard !all.isEmpty else { return (watch.id, nil, aired) }
                    let watched = { (ep: MetaVideo) in history.watchedEpisode(watch.id, ep.season ?? 0, ep.episode ?? 0) }
                    guard let furthest = all.lastIndex(where: watched) else { return (watch.id, false, aired) }
                    return (watch.id, !all[(furthest + 1)...].contains(where: \.hasAired), aired)
                }
            }
            var found: [String: (caughtUp: Bool?, aired: Date?)] = [:]
            for await (id, caughtUp, aired) in group { found[id] = (caughtUp, aired) }
            return found
        }
        for watch in shows {
            out.aired[watch.id] = found[watch.id]?.aired
            if watch.watched == 0 {
                out.states[watch.id] = .watching
            } else if found[watch.id]?.caughtUp == true {
                out.states[watch.id] = .finished
            } else {
                out.states[watch.id] = watch.started || now.timeIntervalSince(watch.last) < leftAfter ? .watching : .left
            }
        }
        return out
    }

    /// Your own rows' titles: shows left, and what you finished long ago.
    struct Own: Sendable {
        var pickBackUp: [Title] = []
        var rewatch: [Title] = []
        /// Your shows with an episode out this week, the latest first.
        var newEpisodes: [Title] = []
        var airingToday: [Title] = []
    }

    /// Watch Again and its kind: finished at least this long ago.
    static let rewatchAfterDays = 180
    /// The days a rewatch row is up (of the day's chance).
    static let rewatchChance = 0.45
    /// Finished titles looked up for it (a request each, kept a month).
    static let rewatchLookups = 60

    static func own(watches: [Watch], standings full: Standings, now: Date, day: String) async -> Own {
        let standings = full.states
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let airing = watches.filter { watch in full.aired[watch.id].map { $0 > weekAgo } ?? false }
            .sorted { (full.aired[$0.id] ?? now) > (full.aired[$1.id] ?? now) }
        let left = watches.filter { standings[$0.id] == .left }
            .sorted { engagement($0, now: now) > engagement($1, now: now) }
            .prefix(rowLength)
        let longAgo = now.addingTimeInterval(-Double(rewatchAfterDays) * 86_400)
        // A year ago first (its row needs them), then the most watched, a
        // little of the day's chance among them.
        let finished = watches.filter { standings[$0.id] == .finished && $0.last < longAgo }
            .sorted { a, b in
                func score(_ w: Watch) -> Double {
                    let ago = now.timeIntervalSince(w.last) / 86_400
                    return ((335...395).contains(ago) ? 1 : 0) + amount(w) + 0.5 * jitter(day, "rewatch", w.id)
                }
                return score(a) > score(b)
            }
            .prefix(rewatchLookups)
        struct Box: Sendable { let title: Title? }
        async let leftTitles = boundedConcurrentMap(Array(left), limit: 8) {
            Box(title: await TMDBService.cueTitle(imdbID: $0.id, type: $0.type))
        }
        async let airingTitles = boundedConcurrentMap(airing, limit: 8) {
            Box(title: await TMDBService.cueTitle(imdbID: $0.id, type: $0.type))
        }
        async let finishedTitles = boundedConcurrentMap(Array(finished), limit: 8) {
            Box(title: await TMDBService.cueTitle(imdbID: $0.id, type: $0.type))
        }
        let yours = await airingTitles.compactMap(\.title)
        let today = yours.filter { full.aired[$0.item.id].map(Calendar.current.isDateInToday) ?? false }
        return Own(pickBackUp: await leftTitles.compactMap(\.title), rewatch: await finishedTitles.compactMap(\.title),
                   newEpisodes: yours, airingToday: today)
    }

    /// The seasonal rows' keywords in season now, by season.
    static func seasonalKeywords(now: Date) -> [(String, Set<Int>)] {
        var out: [(String, Set<Int>)] = []
        for recipe in seasonal(now: now) {
            guard let season = recipe.season else { continue }
            let text = [recipe.movie?["with_keywords"], recipe.tv?["with_keywords"]].compactMap { $0 }.joined(separator: "|")
            let ids = Set(text.split(whereSeparator: { $0 == "|" || $0 == "," }).compactMap { Int($0) })
            guard !ids.isEmpty else { continue }
            if let index = out.firstIndex(where: { $0.0 == season }) { out[index].1.formUnion(ids) }
            else { out.append((season, ids)) }
        }
        return out
    }
}

// MARK: - What you pass over

extension CueRows {
    /// What you looked at on Cue's rows and left: a title the focus rested
    /// on (`dwell`) and didn't open, a row gone through without moving
    /// along it. Days, not times: one count a day. On the device, per
    /// profile, the last `keep` days.
    struct Passes: Codable, Sendable {
        /// Title id: the days it was looked at and not opened.
        var titles: [String: [String]] = [:]
        /// Catalogue row (recipe id): the days gone through, and explored.
        var passedRows: [String: [String]] = [:]
        var exploredRows: [String: [String]] = [:]

        static let keep = 30
        /// Looked at and left this many days: out of the rows until its
        /// last pass is `keep` days old.
        static let outAfter = 3
        /// A row's habit: the last two weeks.
        static let rowWindow = 14

        func count(_ id: String) -> Int { titles[id]?.count ?? 0 }

        func isOut(_ id: String, day: String) -> Bool { count(id) >= Self.outAfter }

        func out(day: String) -> [String] { titles.filter { $0.value.count >= Self.outAfter }.map(\.key) }

        func row(_ recipe: String, day: String) -> (passed: Int, explored: Int) {
            let since = CueRows.dayKey(Date().addingTimeInterval(-Double(Self.rowWindow) * 86_400))
            let explored = (exploredRows[recipe] ?? []).filter { $0 >= since }
            let passed = (passedRows[recipe] ?? []).filter { $0 >= since && !explored.contains($0) }
            return (passed.count, explored.count)
        }

        mutating func prune(today: String) {
            let since = CueRows.dayKey(Date().addingTimeInterval(-Double(Self.keep) * 86_400))
            func trim(_ map: inout [String: [String]]) {
                map = map.compactMapValues { days in
                    let kept = days.filter { $0 >= since }
                    return kept.isEmpty ? nil : kept
                }
            }
            trim(&titles)
            trim(&passedRows)
            trim(&exploredRows)
        }
    }

    /// Records `Passes` from Home's, Movies' and Series' focus.
    @MainActor final class Memory {
        static let shared = Memory()

        /// Focus resting this long on a title is looking at it.
        static let dwell: Double = 1.5
        /// Moving this far along a row is exploring it.
        static let explore = 2

        private var passes = Passes()
        private var profile: Int?
        private var dwellTask: Task<Void, Never>?
        private var saveTask: Task<Void, Never>?
        private var current: (row: String, furthest: Int)?

        private static var activeProfile: Int {
            UserDefaults.standard.object(forKey: ProfileStore.activeKey) as? Int ?? 1
        }

        private static func url(_ profile: Int) -> URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CueCache/cue-rows/passes-p\(profile).json")
        }

        /// This profile's passes (read again after a profile change).
        func snapshot() -> Passes {
            load()
            return passes
        }

        private func load() {
            let active = Self.activeProfile
            guard profile != active else { return }
            profile = active
            current = nil
            passes = (try? Data(contentsOf: Self.url(active)))
                .flatMap { try? JSONDecoder().decode(Passes.self, from: $0) } ?? Passes()
        }

        /// The catalogue row behind a row id ("cue.home.r.horror"), if any.
        private static func recipe(_ row: String) -> String? {
            guard row.hasPrefix("cue."), let range = row.range(of: ".r.") else { return nil }
            return String(row[range.upperBound...])
        }

        func focused(row: String, item: MetaItem, index: Int) {
            guard row.hasPrefix("cue.") else { finishRow(); dwellTask?.cancel(); return }
            load()
            if current?.row != row {
                finishRow()
                current = (row, index)
            } else if let furthest = current?.furthest, index > furthest {
                current?.furthest = index
            }
            dwellTask?.cancel()
            let id = item.id
            dwellTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.dwell))
                guard !Task.isCancelled, let self else { return }
                self.mark(id)
            }
        }

        func opened(_ id: String) {
            load()
            dwellTask?.cancel()
            if passes.titles.removeValue(forKey: id) != nil { save() }
            if let row = current?.row, let recipe = Self.recipe(row) {
                note(&passes.exploredRows, recipe)
                current = nil
            }
        }

        private func mark(_ id: String) {
            note(&passes.titles, id)
        }

        private func finishRow() {
            guard let (row, furthest) = current else { return }
            current = nil
            guard let recipe = Self.recipe(row) else { return }
            if furthest >= Self.explore { note(&passes.exploredRows, recipe) }
            else { note(&passes.passedRows, recipe) }
        }

        private func note(_ map: inout [String: [String]], _ key: String) {
            let today = CueRows.dayKey(Date())
            guard map[key]?.last != today else { return }
            map[key, default: []].append(today)
            save()
        }

        private func save() {
            saveTask?.cancel()
            guard let profile else { return }
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, var passes = self?.passes else { return }
                passes.prune(today: CueRows.dayKey(Date()))
                let url = Self.url(profile)
                await Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(passes) { try? data.write(to: url, options: .atomic) }
                }.value
            }
        }
    }
}
