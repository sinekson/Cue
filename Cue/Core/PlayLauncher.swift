import Combine
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
        let settings: () -> PlayerSettings
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
    func play(_ meta: MetaItem, _ video: MetaVideo?, fromStart: Bool = false, art: String? = nil) {
        cancel()
        PlayStage.shared.show(meta, video, art: art)
        searching = Self.key(meta, video)
        guard !PerformanceSettingsStore.shared.settings.holdPlayStage else { return }
        task = Task { [weak self] in await self?.find(meta, video, fromStart: fromStart) }
    }

    /// A title from its card: a show plays the episode Details' Play would.
    func play(title item: MetaItem, fromStart: Bool = false) {
        cancel()
        PlayStage.shared.show(item, nil)
        searching = Self.key(item, nil)
        guard !PerformanceSettingsStore.shared.settings.holdPlayStage else { return }
        task = Task { [weak self] in
            guard let self, let (meta, video) = await self.target(item) else { return }
            self.searching = Self.key(meta, video)
            PlayStage.shared.show(meta, video)
            await self.find(meta, video, fromStart: fromStart)
        }
    }

    /// The source picker for a title (a show: the episode Play would start).
    func chooseSource(title item: MetaItem) {
        guard item.isSeries else { SourcePicker.shared.open(item, nil); return }
        cancel()
        PlayStage.shared.show(item, nil)
        searching = Self.key(item, nil)
        task = Task { [weak self] in
            guard let self, let (meta, video) = await self.target(item) else { return }
            self.searching = nil
            SourcePicker.shared.open(meta, video)
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
        let settings = context.settings()
        await model.load(addonManager: context.addonManager, perTier: settings.sourcesPerSizeTier,
                         filtersEnabled: settings.sourceFiltersEnabled, forceRefresh: forceRefresh,
                         streamTimeout: TimeInterval(settings.sourceSearchTimeoutSeconds))
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
