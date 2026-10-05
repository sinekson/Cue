import SwiftUI

// MARK: - Shared watched badge

/// A small "watched" tick shown on a movie poster once it's been marked watched,
/// so every theme surfaces watched state consistently. Series aren't badged at
/// the card level (their episodes carry watched state individually).
struct WatchedTickBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.green))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 3)
            .padding(10)
    }
}

private struct WatchedBadgeModifier: ViewModifier {
    @EnvironmentObject private var watched: WatchedStore
    let item: MetaItem?
    let alignment: Alignment
    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if let item, !item.isSeries, watched.isWatched(item) { WatchedTickBadge() }
        }
    }
}

extension View {
    /// Overlays a watched tick on a movie card when it's been marked watched.
    func watchedBadge(_ item: MetaItem?, alignment: Alignment = .topTrailing) -> some View {
        modifier(WatchedBadgeModifier(item: item, alignment: alignment))
    }
}

// MARK: - Continue Watching actions (its hold menu's: `ContinueMenuAction`)

/// What the Continue Watching hold menu does to a row, through the same
/// paths the player and Details use.
@MainActor
enum ContinueActions {
    /// True for a series row, whatever type spelling a sync source used.
    static func isSeries(_ progress: WatchProgress) -> Bool {
        ["series", "tv", "show", "tvshow", "anime"].contains(progress.type.lowercased())
    }

    /// The (season, episode) a row is for, from the stored columns or — when
    /// a sync source dropped them — from a row key shaped "…:<season>:<episode>"
    /// (e.g. "tt0903747:5:6"). Only the two trailing components AFTER the show
    /// id are trusted, so an exotic "kitsu:1234:5" show id is not mistaken for
    /// season 1234.
    static func episode(_ progress: WatchProgress) -> (season: Int, episode: Int)? {
        if let season = progress.season, let episode = progress.episode { return (season, episode) }
        let prefix = progress.metaID + ":"
        guard progress.id.hasPrefix(prefix) else { return nil }
        let tail = progress.id.dropFirst(prefix.count).split(separator: ":")
        guard tail.count == 2, let season = Int(tail[0]), let episode = Int(tail[1]) else { return nil }
        return (season, episode)
    }

    /// The title a row is for (the show, for an episode), as Details opens it.
    static func title(_ progress: WatchProgress) -> MetaItem {
        MetaItem(id: progress.metaID, type: isSeries(progress) ? "series" : "movie", name: progress.name,
                 poster: progress.poster, background: progress.background, logo: progress.logo)
    }

    /// Mark it watched, as the player does when it finishes: the episode
    /// (or film) is recorded in watch history and its progress row retired —
    /// so an episode's card moves on to the next one (Home's Next Up), a
    /// film leaves the row. Synced like any mark.
    static func markWatched(_ progress: WatchProgress, watched: WatchedStore, progressStore: ProgressStore) {
        let meta = title(progress)
        var video: MetaVideo?
        if isSeries(progress) {
            guard let (season, episode) = episode(progress) else { return }
            video = MetaVideo(id: progress.id, title: progress.episodeTitle ?? progress.name,
                              season: season, episode: episode, thumbnail: progress.episodeThumbnail)
            // Recorded FIRST, as a user action (not `fromPlayback`): the
            // player's `onFinished` marks the same key as "already reported by
            // the stop scrobble", which would make the Trakt push skip it.
            if !watched.isWatched(contentID: progress.metaID, season: season, episode: episode) {
                watched.mark(meta: meta, video: video)
            }
        } else if !watched.isWatched(meta) {
            watched.mark(meta: meta, video: nil)
        }
        // Then the progress row goes, with its account / Stremio resume point,
        // through the path in-app playback uses.
        progressStore.markFinished(meta: meta, video: video)
    }

    /// Off Continue Watching without marking anything watched — the whole
    /// show, like Netflix; synced, so it's gone on the other devices too.
    static func remove(_ progress: WatchProgress, progressStore: ProgressStore) {
        progressStore.removeShow(metaID: progress.metaID, notifySync: true)
    }
}
