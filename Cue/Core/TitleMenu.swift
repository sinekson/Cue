import SwiftUI
import UIKit

/// Holding Select on a title's card, anywhere — Home's rows, Search, Library,
/// folders, See All, Details' More page: Cue's hold menu (`HoldMenu`), with
/// the same items in the same order everywhere (SwiftUI cards:
/// `.titleMenu(_:)`): Discover (its genre, style and theme filled in), the
/// watched mark, Library, Not for Me, Use as Background. No Play or Choose Source: Details is the way to play
/// (Continue Watching's menu puts its own round these). Red only for what
/// the menu can't undo: none here (Remove from Library turns into Add).
@MainActor
final class TitleMenu {
    static let shared = TitleMenu()

    typealias Entry = MenuEntry

    private weak var library: LibraryStore?
    private weak var watched: WatchedStore?
    private weak var progress: ProgressStore?
    private weak var addonManager: AddonManager?
    /// Discover filled in from the title, a page on the tab showing
    /// (`RootView` sets it).
    var openDiscover: ((MetaItem) -> Void)?

    func configure(library: LibraryStore, watched: WatchedStore, progress: ProgressStore,
                   addonManager: AddonManager) {
        self.library = library
        self.watched = watched
        self.progress = progress
        self.addonManager = addonManager
    }

    func entries(for item: MetaItem) -> [Entry] {
        guard let library, let watched else { return [] }
        var entries: [Entry] = []
        // Where it takes you, as Continue Watching's Go to (first there).
        if let openDiscover {
            entries.append(Entry(title: "Discover", icon: "safari") { openDiscover(item) })
        }
        if item.isSeries {
            if let aired = airedEpisodes(item), !aired.isEmpty, aired.allSatisfy({ isWatched(item.id, $0) }) {
                entries.append(Entry(title: "Mark Series as Unwatched", icon: "eye.slash") {
                    watched.remove(keys: aired.map {
                        WatchedItem.key(contentID: item.id, season: $0.season, episode: $0.episode)
                    })
                })
            } else {
                entries.append(Entry(title: "Mark Series as Watched", icon: "checkmark.circle") { [weak self] in
                    self?.markSeriesWatched(item)
                })
            }
        } else {
            let seen = watched.isWatched(item)
            entries.append(Entry(title: seen ? "Mark as Unwatched" : "Mark as Watched",
                                 icon: seen ? "eye.slash" : "checkmark.circle") { [weak self] in
                self?.toggleWatched(movie: item)
            })
        }

        let saved = library.contains(item)
        entries.append(Entry(title: saved ? "Remove from Library" : "Add to Library",
                             icon: saved ? "bookmark.slash" : "bookmark") { library.toggle(item) })

        entries.append(TitleRatings.notForMeEntry(item))

        entries.append(Entry(title: "Use as Background", icon: "photo") {
            BackgroundStore.shared.use(item)
        })

        return entries
    }


    /// The show's aired episodes (specials left out, as the mark), if its
    /// list has been looked up this run; nil: not known yet, so the menu
    /// offers to mark it (a second mark only adds what's missing).
    private func airedEpisodes(_ item: MetaItem) -> [MetaVideo]? {
        SeriesEpisodes.known[item.id].map {
            SeriesEpisodes.inPlayOrder($0).filter { ($0.season ?? 0) > 0 && $0.hasAired }
        }
    }

    private func isWatched(_ id: String, _ episode: MetaVideo) -> Bool {
        watched?.isWatched(contentID: id, season: episode.season, episode: episode.episode) ?? false
    }

    /// As Continue Watching's: marked watched, its progress row goes too.
    private func toggleWatched(movie: MetaItem) {
        guard let watched else { return }
        watched.toggleMovie(movie)
        if watched.isWatched(movie) { progress?.markFinished(meta: movie, video: nil) }
    }

    /// Every aired episode (specials left out, as Details' season mark), and
    /// the show off Continue Watching.
    private func markSeriesWatched(_ item: MetaItem) {
        guard let addonManager else { return }
        Task { [weak self] in
            let meta = await SeriesEpisodes.fullMeta(for: item, addonManager: addonManager)
            guard let self, let watched = self.watched else { return }
            for episode in SeriesEpisodes.inPlayOrder(meta)
            where (episode.season ?? 0) > 0 && episode.hasAired
                && !watched.isWatched(contentID: meta.id, season: episode.season, episode: episode.episode) {
                watched.mark(meta: meta, video: episode)
            }
            self.progress?.removeShow(metaID: meta.id, notifySync: true)
        }
    }
}

extension View {
    /// Holding Select on a title's card: `TitleMenu` (see `HoldMenu`).
    func titleMenu(_ item: MetaItem) -> some View {
        modifier(TitleHoldMenu(item: item))
    }
}

/// `.titleMenu`: the card's own focus, for its hold menu.
private struct TitleHoldMenu: ViewModifier {
    let item: MetaItem
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .holdMenu(focused: focused) { TitleMenu.shared.entries(for: item) }
    }
}
