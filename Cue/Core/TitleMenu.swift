import SwiftUI
import UIKit

/// Holding Select on a title's card, anywhere — Home's rows, Search, Library,
/// folders, See All, Details' More page: Cue's hold menu (`HoldMenu`), with
/// the same items everywhere. Pressing the card opens Details, so these are the
/// shortcuts past it, shown by `HoldMenu` (SwiftUI cards: `.titleMenu(_:)`).
@MainActor
final class TitleMenu {
    static let shared = TitleMenu()

    /// Where the card is. In Library, removing it is what you'd hold for: it
    /// goes last, in red.
    enum Place { case standard, library }

    typealias Entry = MenuEntry

    private weak var library: LibraryStore?
    private weak var watched: WatchedStore?
    private weak var progress: ProgressStore?
    private weak var addonManager: AddonManager?

    func configure(library: LibraryStore, watched: WatchedStore, progress: ProgressStore,
                   addonManager: AddonManager) {
        self.library = library
        self.watched = watched
        self.progress = progress
        self.addonManager = addonManager
    }

    func entries(for item: MetaItem, in place: Place = .standard) -> [Entry] {
        guard let library, let watched else { return [] }
        let launcher = PlayLauncher.shared
        var entries: [Entry] = []
        let started = isStarted(item)
        entries.append(Entry(title: started ? "Resume" : "Play", icon: "play.fill") {
            launcher.play(title: item)
        })
        if started {
            entries.append(Entry(title: "Start Over", icon: "gobackward") {
                launcher.play(title: item, fromStart: true)
            })
        }
        entries.append(Entry(title: "Choose Source", icon: "list.and.film") {
            launcher.chooseSource(title: item)
        })

        let saved = library.contains(item)
        let libraryEntry = Entry(title: saved ? "Remove from Library" : "Add to Library",
                                 icon: saved ? "bookmark.slash" : "bookmark",
                                 destructive: saved && place == .library) { library.toggle(item) }
        if place == .standard { entries.append(libraryEntry) }

        if item.isSeries {
            entries.append(Entry(title: "Mark Series as Watched", icon: "checkmark.circle",
                                 confirm: "Mark Every Aired Episode") { [weak self] in
                self?.markSeriesWatched(item)
            })
        } else {
            let seen = watched.isWatched(item)
            entries.append(Entry(title: seen ? "Mark as Unwatched" : "Mark as Watched",
                                 icon: seen ? "eye.slash" : "checkmark.circle") { [weak self] in
                self?.toggleWatched(movie: item)
            })
        }

        if place == .library { entries.append(libraryEntry) }
        return entries
    }


    /// Started and not finished: the film, or an episode of the show.
    private func isStarted(_ item: MetaItem) -> Bool {
        guard let progress else { return false }
        func started(_ p: WatchProgress) -> Bool { p.fraction > 0.02 && p.fraction < 0.95 }
        if item.isSeries { return progress.items.values.contains { $0.metaID == item.id && started($0) } }
        return progress.progress(for: ProgressStore.key(metaID: item.id, video: nil)).map(started) ?? false
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
    func titleMenu(_ item: MetaItem, in place: TitleMenu.Place = .standard) -> some View {
        modifier(TitleHoldMenu(item: item, place: place))
    }
}

/// `.titleMenu`: the card's own focus, for its hold menu.
private struct TitleHoldMenu: ViewModifier {
    let item: MetaItem
    let place: TitleMenu.Place
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .holdMenu(focused: focused) { TitleMenu.shared.entries(for: item, in: place) }
    }
}
