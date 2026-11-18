import Combine
import UIKit
import Foundation

/// Play, seamless: a source is found on the stage (`PlayStage`) and the player
/// opens as soon as the first link is in (the first add-on in order that has
/// one; an aggregator like AIOStreams has already sorted and filtered them).
/// None found: the source list comes up on the stage (`SourcePicker`). Back
/// cancels.
@MainActor
final class PlayLauncher: ObservableObject {
    static let shared = PlayLauncher()

    /// The title / episode a source is being found for (`key`).
    @Published private(set) var searching: String?

    /// What finding and playing needs from the app, set once at launch.
    struct Context {
        let addonManager: AddonManager
        let progress: ProgressStore
        let watched: WatchedStore
        /// Plays a link: from its saved position, or from the start.
        let start: (MetaItem, MetaVideo?, StreamEntry, [StreamEntry], _ fromStart: Bool) -> Void
    }

    private var context: Context?
    private var model: StreamsViewModel?
    private var modelKey: String?
    private var task: Task<Void, Never>?

    func configure(_ context: Context) { self.context = context }

    static func key(_ meta: MetaItem, _ video: MetaVideo?) -> String { meta.id + "|" + (video?.id ?? "") }

    /// This title or episode.
    func play(_ meta: MetaItem, _ video: MetaVideo?, fromStart: Bool = false, art: String? = nil,
              bands: String? = nil) {
        cancel()
        PlayStage.shared.show(meta, video, art: art, bands: bands)
        searching = Self.key(meta, video)
        task = Task { [weak self] in await self?.find(meta, video, fromStart: fromStart) }
    }

    /// A title from its card: a show plays the episode Details' Play would.
    func play(title item: MetaItem, fromStart: Bool = false) {
        cancel()
        PlayStage.shared.show(item, nil)
        searching = Self.key(item, nil)
        task = Task { [weak self] in
            guard let self, let (meta, video) = await self.target(item) else { return }
            self.searching = Self.key(meta, video)
            PlayStage.shared.show(meta, video)
            await self.find(meta, video, fromStart: fromStart)
        }
    }

    /// The card whose hold menu asked (focus back on it as the entry runs):
    /// the stage grows out of it as Details opens out of it. Home's
    /// billboard card always (as Details); any other card with Opening
    /// Details on Grow, the picture Details' card shows framed as Details'
    /// way in frames it (Today's Pick: its own picture).
    func grownFrom(_ item: MetaItem) async -> (window: DetailTransition.Window, art: String?, shrinksBack: Bool)? {
        if let card = StagePictureView.homeCardShown, card.shownItemID == item.id,
           let window = card.openingWindow(), window.card.minY >= 0 {
            return (window, card.shownPictureURL, true)
        }
        guard !DetailTransition.crossfades,
              let key = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return nil }
        if let cell = UIFocusSystem.focusSystem(for: key)?.focusedItem as? FixedFocusShowcaseCell,
           cell.spotlight, cell.item?.id == item.id, let window = cell.backWindow() {
            return (window, cell.shownArt, true)
        }
        guard let card = DetailTransition.focusedCard(in: key) else { return nil }
        // Taken at the press; the picture (decoded at focus) waited on briefly.
        let picture = TitlePictures.shared.shown(item)
        let url = await withTaskGroup(of: String?.self) { group in
            group.addTask { await picture.value }
            group.addTask { try? await Task.sleep(for: .seconds(Self.pictureWait)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let url else { return nil }
        let target = StagePictureView.detailsCard
        let framed = StagePictureView.cardPicture(in: target, url: url)
        let scale = max(card.width / target.width, card.height / target.height)
        let shown = CGRect(x: card.midX + (framed.minX - target.midX) * scale,
                           y: card.midY + (framed.minY - target.midY) * scale,
                           width: framed.width * scale, height: framed.height * scale)
        return (DetailTransition.Window(card: card, picture: shown, screen: card), url, false)
    }

    private static let pictureWait = 0.5

    /// The source picker for a title (a show: the episode Play would start).
    /// The stage comes in whole: the card's picture, the logo and a show's
    /// episode waited on together (`readyWait` at most), so nothing lands
    /// mid-move. A show's episode not in by then: the stage first, the list
    /// once it's known (the same picture: never the episode's still).
    func chooseSource(title item: MetaItem) {
        cancel()
        let found = Task { [weak self] in await self?.target(item) }
        task = Task { [weak self] in
            async let card = self?.grownFrom(item)
            async let logo: Void = Self.readyLogo(item)
            async let early = Self.within(Self.readyWait) { await found.value ?? nil }
            // Details' picture with Fade too (no grow): never the episode's.
            async let shown = Self.within(Self.readyWait) { await TitlePictures.shared.shown(item).value }
            let grown = await card
            _ = await logo
            let target = await early
            let picture = await shown
            let art = grown?.art ?? picture ?? nil
            guard let self, !Task.isCancelled else { return found.cancel() }
            let open = { (meta: MetaItem, video: MetaVideo?) in
                // The card's own record first, so the stage keeps its logo
                // (the one made ready): a show's full record can name
                // another file. Both in one pass: drawn once, as the last.
                if PlayStage.shared.scene == nil {
                    PlayStage.shared.show(item, nil, art: art, bands: art, from: grown?.window,
                                          shrinksBack: grown?.shrinksBack ?? false)
                }
                SourcePicker.shared.open(meta, video, art: art, bands: art, from: grown?.window,
                                         shrinksBack: grown?.shrinksBack ?? false)
            }
            if let (meta, video) = target { return open(meta, video) }
            PlayStage.shared.show(item, nil, art: art, bands: art, from: grown?.window,
                                  shrinksBack: grown?.shrinksBack ?? false)
            self.searching = Self.key(item, nil)
            guard let (meta, video) = await found.value ?? nil, !Task.isCancelled else { return }
            self.searching = nil
            open(meta, video)
        }
    }

    /// The stage's logo decoded and trimmed (`RemoteImage` shows it from
    /// its first frame).
    private static func readyLogo(_ item: MetaItem) async {
        guard let logo = item.logo ?? BillboardPicks.metaHubLogo(item.id) else { return }
        _ = await within(readyWait) { await ImageCache.shared.preload(logo, maxDimension: PictureSize.logo) }
    }

    private static let readyWait = 0.5

    /// `work`'s answer, or nil after `seconds`.
    private static func within<T: Sendable>(_ seconds: Double,
                                            _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The links found so far for this title or episode, while the sweep that
    /// started it is the last one: it goes on behind the player.
    func links(_ meta: MetaItem, _ video: MetaVideo?) -> [StreamEntry]? {
        modelKey == Self.key(meta, video) ? model?.entries : nil
    }

    /// The episode after this one, ready to play.
    struct NextEpisode {
        let meta: MetaItem
        let video: MetaVideo
        let entry: StreamEntry
        let links: [StreamEntry]
        let resume: Double?
    }

    /// The show's episodes that can be played, in play order. Nil: none found.
    func episodes(of meta: MetaItem) async -> (meta: MetaItem, episodes: [MetaVideo])? {
        guard let context else { return nil }
        let full = meta.videos?.isEmpty == false
            ? meta : await SeriesEpisodes.fullMeta(for: meta, addonManager: context.addonManager)
        let episodes = SeriesEpisodes.inPlayOrder(full).filter(\.hasAired)
        return episodes.isEmpty ? nil : (full, episodes)
    }

    /// The next episode and its link. Nil at the end of the show, for one not
    /// aired yet, or with no playable link.
    func next(after meta: MetaItem, _ video: MetaVideo, current: StreamEntry) async -> NextEpisode? {
        guard let (full, episodes) = await episodes(of: meta),
              let at = episodes.firstIndex(where: { $0.id == video.id }), at + 1 < episodes.count else { return nil }
        return await ready(episodes[at + 1], of: full, current: current)
    }

    /// An episode with its link: the same release as `current` where the add-on
    /// says so (`bingeGroup`), else the first, as Play.
    func ready(_ video: MetaVideo, of full: MetaItem, current: StreamEntry) async -> NextEpisode? {
        guard let context else { return nil }
        let model = StreamsViewModel(meta: full, video: video)
        await sweep(model, context)
        let links = model.entries.filter { !$0.stream.isTorrent }
        let group = current.stream.behaviorHints?.bingeGroup
        guard let entry = links.first(where: { group != nil && $0.stream.behaviorHints?.bingeGroup == group })
                ?? links.first else { return nil }
        let saved = context.progress.progress(for: ProgressStore.key(metaID: full.id, video: video))
        return NextEpisode(meta: full, video: video, entry: entry, links: model.entries,
                           resume: saved?.isStarted == true ? saved?.positionSeconds : nil)
    }

    /// The add-ons asked again, past every cache: the links in hand went bad,
    /// or Refresh. `update` has the links so far and the add-ons that answered.
    func freshLinks(_ meta: MetaItem, _ video: MetaVideo?,
                    update: (([StreamEntry], Set<String>) -> Void)? = nil) async -> [StreamEntry] {
        guard let context else { return [] }
        let model = StreamsViewModel(meta: meta, video: video)
        let watching = update.map { update in
            model.$entries.dropFirst().sink { [weak model] entries in
                update(entries, model?.finishedAddonNames ?? [])
            }
        }
        await sweep(model, context, forceRefresh: true)
        watching?.cancel()
        return model.entries
    }

    private func sweep(_ model: StreamsViewModel, _ context: Context, forceRefresh: Bool = false) async {
        await model.load(addonManager: context.addonManager, forceRefresh: forceRefresh)
    }

    /// Back while searching: it stops.
    func cancel() {
        task?.cancel()
        task = nil
        model = nil
        if searching != nil { PlayStage.shared.clear() }
        searching = nil
    }

    /// The title with the episode to play (nil for a film); nil if cancelled.
    private func target(_ item: MetaItem) async -> (MetaItem, MetaVideo?)? {
        guard item.isSeries, let context else { return (item, nil) }
        let full = await SeriesEpisodes.fullMeta(for: item, addonManager: context.addonManager)
        guard !Task.isCancelled else { return nil }
        let video = SeriesEpisodes.playTarget(full.id, in: SeriesEpisodes.inPlayOrder(full),
                                              progress: context.progress, watched: context.watched)
        return (full, video)
    }

    private func find(_ meta: MetaItem, _ video: MetaVideo?, fromStart: Bool) async {
        guard let context else { return }
        let key = Self.key(meta, video)
        let model = StreamsViewModel(meta: meta, video: video)
        self.model = model
        modelKey = key
        model.onFirstLink = { [weak self, weak model] entry in
            guard let self, let model, self.searching == key else { return }
            self.searching = nil
            context.start(meta, video, entry, model.entries, fromStart)
        }
        await sweep(model, context)
        guard !Task.isCancelled, searching == key else { return }
        // Nothing playable came in: the list shows what there is.
        searching = nil
        SourcePicker.shared.open(meta, video, fromStart: fromStart)
    }
}
