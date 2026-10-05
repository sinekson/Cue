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
        return picks
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

    /// A logo for IMDb titles that came without one (MetaHub's; the billboard
    /// falls back to the name when it doesn't load).
    private static func withLogo(_ item: MetaItem) -> MetaItem {
        guard item.logo == nil, item.id.hasPrefix("tt") else { return item }
        return MetaItem(id: item.id, type: item.type, name: item.name, poster: item.poster,
                        background: item.background,
                        logo: "https://images.metahub.space/logo/medium/\(item.id)/img",
                        description: item.description, releaseInfo: item.releaseInfo,
                        imdbRating: item.imdbRating, runtime: item.runtime, genres: item.genres,
                        cast: item.cast, videos: item.videos)
    }
}
