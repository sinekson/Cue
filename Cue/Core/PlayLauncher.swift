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
    func play(title item: MetaItem, fromStart: Bool = false) {
        cancel()
        search = Search(key: Self.key(item, nil), title: item.name, episode: nil, overlay: true)
        task = Task { [weak self] in
            guard let self, let (meta, video) = await self.target(item) else { return }
            self.search?.key = Self.key(meta, video)
            self.search?.episode = video?.seasonEpisodeCode
            await self.find(meta, video, fromStart: fromStart)
        }
    }

    /// The source picker for a title (a show: the episode Play would start).
    func chooseSource(title item: MetaItem) {
        guard item.isSeries else { SourcePicker.shared.open(item, nil); return }
        cancel()
        search = Search(key: Self.key(item, nil), title: item.name, episode: nil, overlay: true)
        task = Task { [weak self] in
            guard let self, let (meta, video) = await self.target(item) else { return }
            self.search = nil
            SourcePicker.shared.open(meta, video)
        }
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
