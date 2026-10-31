import Foundation

/// Play, seamless: a source is found IN PLACE and the player opens as soon
/// as the first link is in (the first add-on in order that has one; an
/// aggregator like AIOStreams has already sorted and filtered them). None
/// found: the source picker opens (`SourcePicker`).
///
/// Details' Play says it's searching on its own button; from anywhere else
/// (a card's menu, an episode's) the root shows it over the app
/// (`search.overlay`), Back cancelling.
@MainActor
final class PlayLauncher: ObservableObject {
    static let shared = PlayLauncher()

    struct Search: Equatable {
        /// The title / episode a source is being found for (`key`).
        var key: String
        /// What the overlay names: the title, and the episode once known.
        let title: String
        var episode: String?
        /// Shown over the app (else the caller shows it, as Details' Play).
        let overlay: Bool
    }

    @Published private(set) var search: Search?
    var searching: String? { search?.key }

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
    func play(_ meta: MetaItem, _ video: MetaVideo?, fromStart: Bool = false, overlay: Bool = true) {
        cancel()
        search = Search(key: Self.key(meta, video), title: meta.name,
                        episode: video?.seasonEpisodeCode, overlay: overlay)
        task = Task { [weak self] in await self?.find(meta, video, fromStart: fromStart) }
    }

    /// A title from its card: a show plays the episode Details' Play would.
    /// (`overlay` false: the caller shows it — the billboard's Play.)
    func play(title item: MetaItem, fromStart: Bool = false, overlay: Bool = true) {
        cancel()
        search = Search(key: Self.key(item, nil), title: item.name, episode: nil, overlay: overlay)
        task = Task { [weak self] in
            guard let self, let (meta, video) = await self.target(item) else { return }
            self.search?.key = Self.key(meta, video)
            self.search?.episode = video?.seasonEpisodeCode
            await self.find(meta, video, fromStart: fromStart)
        }
    }

    /// The source picker for a title (a show: the episode Play would start).
    func chooseSource(title item: MetaItem, overlay: Bool = true) {
        guard item.isSeries else { SourcePicker.shared.open(item, nil); return }
        cancel()
        search = Search(key: Self.key(item, nil), title: item.name, episode: nil, overlay: overlay)
        task = Task { [weak self] in
            guard let self, let (meta, video) = await self.target(item) else { return }
            self.search = nil
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

    /// The next episode and its link: the same release as `current` where the
    /// add-on says so (`bingeGroup`), else the first, as Play. Nil at the end
    /// of the show, for one not aired yet, or with no playable link.
    func next(after meta: MetaItem, _ video: MetaVideo, current: StreamEntry) async -> NextEpisode? {
        guard let context else { return nil }
        let full = meta.videos?.isEmpty == false
            ? meta : await SeriesEpisodes.fullMeta(for: meta, addonManager: context.addonManager)
        let episodes = SeriesEpisodes.inPlayOrder(full)
        guard let at = episodes.firstIndex(where: { $0.id == video.id }), at + 1 < episodes.count,
              episodes[at + 1].hasAired else { return nil }
        let next = episodes[at + 1]

        let model = StreamsViewModel(meta: full, video: next)
        let settings = context.settings()
        await model.load(addonManager: context.addonManager, perTier: settings.sourcesPerSizeTier,
                         filtersEnabled: settings.sourceFiltersEnabled,
                         streamTimeout: TimeInterval(settings.sourceSearchTimeoutSeconds))
        let links = model.entries.filter { !$0.stream.isExternal && !$0.stream.isTorrent }
        let group = current.stream.behaviorHints?.bingeGroup
        guard let entry = links.first(where: { group != nil && $0.stream.behaviorHints?.bingeGroup == group })
                ?? links.first else { return nil }
        let saved = context.progress.progress(for: ProgressStore.key(metaID: full.id, video: next))
        return NextEpisode(meta: full, video: next, entry: entry, links: model.entries,
                           resume: saved?.isStarted == true ? saved?.positionSeconds : nil)
    }

    /// Back while searching: it stops.
    func cancel() {
        task?.cancel()
        task = nil
        model = nil
        search = nil
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
            guard let self, let model, self.search?.key == key else { return }
            self.search = nil
            context.start(meta, video, entry, model.entries, fromStart)
        }
        let settings = context.settings()
        await model.load(addonManager: context.addonManager, perTier: settings.sourcesPerSizeTier,
                         filtersEnabled: settings.sourceFiltersEnabled,
                         streamTimeout: TimeInterval(settings.sourceSearchTimeoutSeconds))
        guard !Task.isCancelled, search?.key == key else { return }
        // Nothing playable came in: the picker shows what there is.
        search = nil
        SourcePicker.shared.open(meta, video, fromStart: fromStart)
    }
}
