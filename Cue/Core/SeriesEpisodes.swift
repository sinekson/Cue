import Foundation

/// A SERIES' EPISODE LIST — one source for the whole app: the add-on's
/// (what the Episodes page shows and playback uses), TMDB's only when no
/// add-on has one. Counts and "latest episode" come from it too, so the
/// facts line ("3 Seasons"), the billboard ("S3 E7") and the Episodes page
/// agree. (TMDB numbers some shows differently — many anime as one long
/// season — which is what made them disagree.)
@MainActor
enum SeriesEpisodes {
    /// The title with its episode list: the first meta add-on that has one,
    /// else TMDB's. Movies and titles nobody knows come back as they were.
    ///
    /// Asks every meta add-on that could serve the id, not just the first:
    /// a series from a catalog-only add-on can come back from the first with
    /// a name and NO episodes. Capped at four — a dozen meta add-ons shouldn't
    /// mean a dozen serial round trips on a title none of them can serve.
    /// `revalidateAfter`: what's on disk is still returned at once, but
    /// older than this it's asked again in the background (Details of an
    /// airing show — `StremioAPI.meta`).
    static func fullMeta(for item: MetaItem, addonManager: AddonManager,
                         revalidateAfter: TimeInterval? = nil) async -> MetaItem {
        var best: MetaItem?
        for addon in addonManager.metaAddons(for: item.type, id: item.id).prefix(4) {
            guard let full = try? await StremioAPI.meta(addon: addon, type: item.type, id: item.id,
                                                        revalidateAfter: revalidateAfter)
            else { continue }
            if best == nil { best = full }
            // A movie has nothing more to find; a series is only done when it
            // has an episode list.
            guard item.isSeries else { break }
            if !(full.videos ?? []).isEmpty { best = full; break }
        }
        let meta = best ?? item
        // Still no episodes: TMDB knows the structure of essentially every
        // series.
        guard meta.isSeries, (meta.videos ?? []).isEmpty, TMDBService.hasAPIKey else { return meta }
        let episodes = await TMDBService.episodes(for: meta.id, type: meta.type)
        guard !episodes.isEmpty else { return meta }
        return MetaItem(
            id: meta.id, type: meta.type, name: meta.name,
            poster: meta.poster, background: meta.background, logo: meta.logo,
            description: meta.description, releaseInfo: meta.releaseInfo,
            imdbRating: meta.imdbRating, runtime: meta.runtime,
            genres: meta.genres, cast: meta.cast, videos: episodes
        )
    }

    /// Every episode in playback order, season by season (as Details' row).
    static func inPlayOrder(_ meta: MetaItem) -> [MetaVideo] {
        meta.playbackSeasons.flatMap { meta.episodesIncludingLinkedSpecials(season: $0) }
    }

    /// The episode Play starts on a show (Details' Play, a card's menu).
    ///
    /// The in-progress episode touched MOST RECENTLY — the one Continue
    /// Watching resumes — not the first in play order, and not one the viewer
    /// has moved past: when an episode at or after it has been watched since,
    /// Play goes on to the next-up episode below, as Home's row does
    /// (`supersededContinueRows`). First in play order would offer "Resume
    /// S1:E3" to someone who left S1E3 half-watched a month ago and has
    /// finished every episode through S2E2 since.
    static func playTarget(_ showID: String, in all: [MetaVideo], progress: ProgressStore,
                           watched: WatchedStore) -> MetaVideo? {
        guard !all.isEmpty else { return nil }
        var latest: (index: Int, progress: WatchProgress)?
        for (index, ep) in all.enumerated() {
            guard let p = progress.progress(for: ep.id), p.fraction > 0.02, p.fraction < 0.95 else { continue }
            if let current = latest, (current.progress.updatedAt, current.progress.id) >= (p.updatedAt, p.id) { continue }
            latest = (index, p)
        }
        if let latest {
            let movedPast = all[latest.index...].contains { ep in
                guard let mark = watched.items[WatchedItem.key(contentID: showID, season: ep.season ?? 0,
                                                               episode: ep.episode)] else { return false }
                return mark.watchedAt > latest.progress.updatedAt
            }
            if !movedPast { return all[latest.index] }
        }

        func isWatched(_ ep: MetaVideo) -> Bool {
            watched.isWatched(contentID: showID, season: ep.season ?? 0, episode: ep.episode)
        }
        // As Continue Watching: aired, or airing within two weeks.
        let unwatched = all.filter { !isWatched($0) && $0.isNextUpCandidate }

        // Next up = the episode right after the FURTHEST watched one.
        if let furthestIndex = all.lastIndex(where: isWatched),
           let next = all[(furthestIndex + 1)...].first(where: \.isNextUpCandidate) {
            return next
        }
        if let firstUnwatched = unwatched.first { return firstUnwatched }
        return all.first
    }

    /// Seasons and episodes, specials (season 0) never counted.
    static func size(of meta: MetaItem) -> TMDBService.ShowSize? {
        let episodes = (meta.videos ?? []).filter { ($0.season ?? 0) > 0 }
        guard !episodes.isEmpty else { return nil }
        return TMDBService.ShowSize(seasons: meta.regularSeasons.count, episodes: episodes.count)
    }

    /// The latest episode that has aired (specials left out).
    static func latestAired(in meta: MetaItem) -> (episode: MetaVideo, aired: Date)? {
        let now = Date()
        return (meta.videos ?? [])
            .filter { ($0.season ?? 0) > 0 }
            .compactMap { video in video.airedDate.map { (video, $0) } }
            .filter { $0.1 <= now }
            .max { $0.1 < $1.1 }
            .map { (episode: $0.0, aired: $0.1) }
    }
}
