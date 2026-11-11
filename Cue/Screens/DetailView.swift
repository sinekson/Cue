import SwiftUI

/// Details' depth below the billboard (see `DetailView.rowsDepth`).
@Observable @MainActor
final class DetailRowsDepth {
    var depth = 0 {
        didSet {
            // Back at the billboard from below (Up, or Back's scroll):
            // the Ups that follow are eaten a moment (`upEaten`).
            if oldValue > 0, depth == 0 { upGuardUntil = CACurrentMediaTime() + Self.upGuard }
        }
    }
    /// Read by the buttons' Up only: no page redraw.
    @ObservationIgnored private var upGuardUntil: CFTimeInterval = 0
    /// One press too many while climbing back (or after Back) opened the
    /// trailer full screen: Up on the buttons does nothing this long after
    /// arriving, while the rows still move, and this long after each Up it ate,
    /// so a burst is eaten whole and a deliberate Up after a pause works.
    static let upGuard: CFTimeInterval = 0.5

    /// Whether this Up arrived too soon after reaching the billboard from below.
    func upEaten() -> Bool {
        let now = CACurrentMediaTime()
        guard now < upGuardUntil || (upGuardUntil > 0 && now < upGuardUntil + 2 && FixedFocusRowsController.moving)
        else { return false }
        upGuardUntil = now + Self.upGuard
        return true
    }
}

/// The focus of a group of controls that may live in another SwiftUI host
/// than the page reading it (SwiftUI focus state doesn't reach across
/// hosts): the group reports where its focus is, the page asks for a move.
@Observable @MainActor
final class FocusBridge<Value: Hashable> {
    /// Where the group's focus is (as it reports it).
    var current: Value?
    /// The page's last request (a new id: apply it).
    private(set) var requested: (value: Value?, id: UUID)?
    func request(_ value: Value?) { requested = (value, UUID()) }
}

/// Owns a control group's focus state, in whatever host it's drawn, and
/// keeps its bridge in step.
struct FocusBridgeHost<Value: Hashable, Content: View>: View {
    let bridge: FocusBridge<Value>
    let defaultValue: Value
    /// Every focus change, as it happens (the page's reactions — called
    /// from HERE: the page can't watch the bridge, and a page-wide redraw
    /// per press is what made the buttons feel slow).
    var onChange: (Value?, Value?) -> Void = { _, _ in }
    @ViewBuilder let content: (FocusState<Value?>.Binding) -> Content
    @FocusState private var focus: Value?

    var body: some View {
        content($focus)
            .defaultFocus($focus, defaultValue)
            .onChange(of: focus) { old, new in
                if bridge.current != new { bridge.current = new }
                onChange(old, new)
            }
            .onChange(of: bridge.requested?.id) { _, _ in focus = bridge.requested?.value }
    }
}

/// Reads the depth for its content alone: only it updates on a change.
/// Details' picture leaned in (`ModeSwap.depthScale`) — opened from the
/// billboard in place, only as its parts arrive (`BillboardOpening
/// .detailsLeaned`). Its own view: the page doesn't observe the opening.
struct DetailLean: ViewModifier {
    private var opening = BillboardOpening.shared
    let depth: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(opening.detailsLeaned ? ModeSwap.depthScale(depth) : 1)
            // (Set from Home's side — no transaction reaches this host.)
            .animation(Motion.move, value: opening.detailsLeaned)
    }
}

struct RowsDepthReader<Content: View>: View {
    let model: DetailRowsDepth
    @ViewBuilder let content: (Int) -> Content
    var body: some View { content(model.depth) }
}

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var meta: MetaItem {
        didSet {
            episodeCache.removeAll()
            allEpisodesCache = nil
            airCache.removeAll()
            metaRevision &+= 1
        }
    }
    /// Bumped when `meta` / `episodeExtras` change: the episode row's memo key.
    private(set) var metaRevision = 0
    private(set) var extrasRevision = 0
    /// The episode row as the page last built it (`DetailView.rowData`).
    var rowMemo: DetailRowData?

    /// An episode's air date as the episode row shows it — worked out ONCE
    /// per episode: parsing and formatting dates for every episode on every
    /// step through the row made a 1,100-episode show crawl.
    struct AirInfo {
        let aired: Bool
        /// "Mar 12, 2023" (aired), or "Airs in 3 days".
        let text: String?
        let countdown: String?
    }
    private var airCache: [String: AirInfo] = [:]
    private static let airDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    func airInfo(_ episode: MetaVideo) -> AirInfo {
        if let hit = airCache[episode.id] { return hit }
        let aired = episode.hasAired
        let countdown = aired ? nil : episode.airCountdownText
        let text = countdown ?? episode.airedDate.map { Self.airDate.string(from: $0) }
        let info = AirInfo(aired: aired, text: text, countdown: countdown)
        airCache[episode.id] = info
        return info
    }

    /// Memoized per-season episode lists. `episodes(season:)` filters, sorts
    /// and dedups the FULL `videos` array per call, and the page's body used
    /// to call it per season, twice per body pass (`seriesPlayTarget` + the
    /// episode row) — on an A8, per D-pad move, for a 400-episode series.
    /// The lists only change when `meta` itself is reassigned (didSet above).
    private var episodeCache: [Int: [MetaVideo]] = [:]
    private var allEpisodesCache: [MetaVideo]?

    func episodes(season: Int) -> [MetaVideo] {
        if let cached = episodeCache[season] { return cached }
        let list = meta.episodesIncludingLinkedSpecials(season: season)
        episodeCache[season] = list
        return list
    }

    /// Every episode in playback order (season by season), memoized.
    var allEpisodesInPlayOrder: [MetaVideo] {
        if let allEpisodesCache { return allEpisodesCache }
        let all = meta.playbackSeasons.flatMap { episodes(season: $0) }
        allEpisodesCache = all
        return all
    }
    @Published var selectedSeason: Int?
    @Published var isLoading = true
    @Published var cast: [TMDBService.CastMember] = []
    @Published var moreLikeThis: [MetaItem] = []
    @Published var collection: TMDBService.CollectionRef?
    @Published var collectionParts: [MetaItem] = []
    @Published var companies: [TMDBService.Company] = []
    /// The About section's facts (TMDB's).
    @Published var about: TMDBService.About?
    /// A trailer that will play is known (resolved ahead): Up opens it
    /// full screen, the hint says so (`DetailTrailerHint`).
    @Published var trailerReady = false
    @Published var mdbRatings: MDBListRatings?
    @Published var crew: [TMDBService.CastMember] = []
    @Published var director: String?
    @Published var country: String?
    @Published var language: String?
    /// The title block's TMDB extras (creator line, status, runtime, …).
    @Published var facts: TMDBService.TitleFacts?
    @Published var releaseDate: String?
    @Published var contentRating: String?
    /// Per-season episode extras (rating / air date), keyed season → episode.
    @Published var episodeExtras: [Int: [Int: TMDBService.EpisodeExtra]] = [:] {
        didSet { extrasRevision &+= 1 }
    }

    init(item: MetaItem) {
        meta = item
    }

    /// The picture this opening shows (`DetailPreparer`: TMDB's, chosen
    /// for it; from the billboard, the billboard's).
    @Published private(set) var shownPicture: String?
    /// …and its logo (the add-on's record often has another one too).
    var shownLogo: String?
    /// The chosen picture wasn't in when the page opened: the page's
    /// background until it is, then it fades in.
    @Published private(set) var pictureLate = false
    /// The page's picture: the chosen one, else the record's.
    var backdropURL: String? { pictureLate ? nil : shownPicture ?? meta.background ?? meta.poster }

    /// Prepared since the press (`DetailPreparer`): the page is BUILT with
    /// it — what's here doesn't land later as a row of updates.
    private var metaIsFull = false
    private var detailApplied = false
    func seed(_ prepared: DetailPreparer.Prepared) {
        let tmdb = prepared.tmdb
        useEpisodeExtras = tmdb.useEpisodes
        shownPicture = prepared.picture
        shownLogo = prepared.logo
        if prepared.pictureLate, !prepared.pictureChosen, let choice = prepared.pictureChoice {
            pictureLate = true
            Task { @MainActor [weak self] in
                await choice.value
                guard let self, let url = prepared.picture else { self?.pictureLate = false; return }
                _ = await ImageCache.shared.preload(url, maxDimension: PictureSize.screen)
                self.shownPicture = url
                self.pictureLate = false
            }
        }
        if let full = prepared.meta {
            meta = full
            metaIsFull = true
            selectedSeason = meta.regularSeasons.first ?? meta.seasons.first
            isLoading = false
        }
        if !prepared.extras.isEmpty { episodeExtras = prepared.extras }
        if mdbRatings == nil, let ratings = prepared.ratings { mdbRatings = ratings }
        if let detail = prepared.detail {
            applyNow(detail: detail, tmdb: tmdb)
            if let parts = prepared.collectionParts { collectionParts = parts }
            detailApplied = true
        }
    }

    /// The add-on to ask again (a background refresh found a change —
    /// `StremioAPI.metaRefreshed`): set by `load`.
    private weak var addonManager: AddonManager?
    private var refreshObserver: NSObjectProtocol?

    /// A background refresh of this title's episode list brought something
    /// new (a just-listed episode): the list again — from disk now — in ONE
    /// change.
    private func watchForRefresh() {
        guard refreshObserver == nil else { return }
        refreshObserver = NotificationCenter.default.addObserver(
            forName: StremioAPI.metaRefreshed, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let id = note.object as? String, id == self.meta.id,
                      let addonManager = self.addonManager else { return }
                Task { @MainActor in
                    let full = await SeriesEpisodes.fullMeta(for: self.meta, addonManager: addonManager)
                    if MetaFreshness.changed(self.meta, full) { self.meta = full }
                }
            }
        }
    }

    deinit {
        if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
    }

    /// Several seasons' extras at once (in parallel), published in ONE
    /// change — one season at a time, each re-rendered the whole page.
    func loadSeasons(_ seasons: [Int]) async {
        guard useEpisodeExtras, meta.isSeries else { return }
        let wanted = seasons.filter { episodeExtras[$0] == nil }
        guard !wanted.isEmpty else { return }
        let id = meta.id, type = meta.type
        let found = await withTaskGroup(of: (Int, [Int: TMDBService.EpisodeExtra]).self) { group in
            for season in wanted {
                group.addTask { (season, await TMDBService.seasonEpisodes(imdbID: id, type: type, season: season)) }
            }
            var all: [Int: [Int: TMDBService.EpisodeExtra]] = [:]
            for await (season, extras) in group where !extras.isEmpty { all[season] = extras }
            return all
        }
        guard !found.isEmpty, !Task.isCancelled else { return }
        var merged = episodeExtras
        merged.merge(found) { old, _ in old }
        episodeExtras = merged
    }

    /// The `.task` that calls this re-runs on every return from Sources or
    /// the player (the cover hides this view); reloading six endpoints and
    /// republishing every row each time was pure churn with a visible flash.
    private var hasLoaded = false

    /// The TMDB enrichment (cast, more-like-this, collection, trailers,
    /// director…) came back empty on the last try. One flaked request used to
    /// leave the page permanently half-loaded — everything below the Play
    /// button missing, latched behind `hasLoaded` with nothing that would
    /// ever ask again. Now the `.task` re-run on every reappearance retries
    /// just the enrichment while this is set.
    private var enrichmentPending = false

    /// The core load (identity + episodes) reached its natural end. Distinct
    /// from `hasLoaded`, which latches at ENTRY: a reappearance while a
    /// cancelled load is still unwinding used to read the latch, skip loading,
    /// and only then have the old task's defer reset it — a page stuck on the
    /// stub for that whole visit.
    private var coreLoaded = false

    /// `settleUntil`: opened through the swap — fetch at once, but change
    /// nothing on the page before then (a redraw mid-animation drops frames).
    func load(addonManager: AddonManager, mdbSettings: MDBListSettings = .default, tmdb: TMDBSettings = .default,
              settleUntil: Date? = nil) async {
        // A previous load is mid-flight or mid-unwind: wait it out briefly.
        // Either it completes (we then just handle the enrichment retry) or
        // its cancellation defer drops the latch and this run loads for real.
        var waited = 0
        while hasLoaded, !coreLoaded, !Task.isCancelled, waited < 30 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        guard !hasLoaded else {
            if enrichmentPending { await enrich(tmdb: tmdb) }
            return
        }
        hasLoaded = true
        // The `.task` is cancelled by `onDisappear` (Play is focusable from
        // the first frame), and a cancelled load leaves the stub meta — with
        // no episodes. Un-latch so the next appearance loads for real.
        defer { if Task.isCancelled { hasLoaded = false } }
        useEpisodeExtras = tmdb.useEpisodes
        // Canonicalize the identity FIRST: TMDB-sourced items arrive as
        // `tmdb:<n>`, but progress / watched / library are keyed by id — the
        // same movie found via different addons would otherwise never match
        // its own Continue Watching entry (and Cinemeta can't serve tmdb: ids
        // at all). Resolve to the IMDb tt id once, cached inside TMDBService.
        var canonical = meta
        if meta.id.hasPrefix("tmdb:"), let n = Int(meta.id.dropFirst("tmdb:".count)),
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !meta.isSeries) {
            canonical = MetaItem(
                id: tt, type: meta.type, name: meta.name,
                poster: meta.poster, background: meta.background, logo: meta.logo,
                description: meta.description, releaseInfo: meta.releaseInfo,
                imdbRating: meta.imdbRating, runtime: meta.runtime,
                genres: meta.genres, cast: meta.cast, videos: meta.videos
            )
        }
        // Kick off TMDB enrichment in parallel with the meta fetch.
        // No key, no enrichment: TMDB now runs on the viewer's own key, and
        // without one every one of these requests is a guaranteed 401.
        let enrichTask = TMDBService.hasAPIKey
            ? Task { [canonical] in await TMDBService.detail(imdbID: canonical.id, type: canonical.type) }
            : nil

        // The one episode list (the add-on's, else TMDB's) — from disk when
        // it's there; an airing show's asked again in the background if
        // older than half an hour (a new episode then comes in one change —
        // `watchForRefresh`).
        self.addonManager = addonManager
        watchForRefresh()
        let full = await SeriesEpisodes.fullMeta(for: canonical, addonManager: addonManager,
                                                 revalidateAfter: canonical.isSeries ? 30 * 60 : nil)
        // Opened through the swap: the page stays as it is until it's over.
        if let wait = settleUntil?.timeIntervalSinceNow, wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
        // (Seeded with it already: only a real change — a new episode.)
        if !metaIsFull || MetaFreshness.changed(meta, full) { meta = full }
        let ratingsTask = Task { await loadMDBRatings(settings: mdbSettings) }
        if selectedSeason == nil {
            selectedSeason = meta.regularSeasons.first ?? meta.seasons.first
        }
        if let season = selectedSeason { await loadSeason(season) }
        // Episodes are ready now — stop blocking the episode section (gated on
        // `isLoading`) behind TMDB / MDBList ratings
        // below. Those are unrelated to episodes and can each be slow
        // themselves; a meta addon that aggregates several sources per request
        // (e.g. AIOMetadata) was already the slow part of this load, and
        // chaining three more independent network calls after it responded
        // just made "episodes" wait even longer for no reason.
        if isLoading { isLoading = false }

        // Unwinding on cancellation: the garnish tasks below were already
        // launched — kill them rather than let three network round trips run
        // to completion for a page the viewer left. (Each aborted visit used
        // to orphan all three.)
        if Task.isCancelled {
            enrichTask?.cancel()
            ratingsTask.cancel()
            return
        }
        coreLoaded = true
        // The rest is garnish riding slow endpoints. Awaiting it HERE kept the
        // load task alive for the whole TMDB round trip, so a cancelled task
        // could not unwind (the latch stayed up, and a quick exit-and-return
        // found a page that refused to load). Applied from its own task; each
        // publish is main-actor via the view model.
        Task { [weak self] in
            guard let self else { return }
            // (Seeded: the page has it — the request refreshed the cache.)
            if !self.detailApplied {
                await self.apply(detail: await enrichTask?.value ?? nil, tmdb: tmdb)
            } else if let collection = self.collection, self.collectionParts.isEmpty, tmdb.useCollections {
                let parts = await TMDBService.collectionItems(id: collection.id)
                    .filter { $0.id != self.meta.id }.deduplicatedByID()
                if !parts.isEmpty { self.collectionParts = parts }
            }
            // A failed load never replaces ratings handed over from the
            // billboard (the row would shrink to the fallback and back).
            let ratings = await ratingsTask.value
            if (ratings != nil || self.mdbRatings == nil), ratings != self.mdbRatings { self.mdbRatings = ratings }
        }
    }

    /// Fetch (or re-fetch) the TMDB enrichment and fold it in. Sets
    /// `enrichmentPending` while it has not succeeded, so a reappearance of
    /// the page tries again instead of leaving the sections empty for good.
    private func enrich(tmdb: TMDBSettings) async {
        guard TMDBService.hasAPIKey else { enrichmentPending = false; return }
        await apply(detail: await TMDBService.detail(imdbID: meta.id, type: meta.type), tmdb: tmdb)
    }

    private func apply(detail: TMDBService.Detail?, tmdb: TMDBSettings) async {
        guard let detail else {
            // Nothing came back (network flake, TMDB hiccup). Remember to
            // retry — but only when a key exists and enrichment was expected.
            enrichmentPending = TMDBService.hasAPIKey
            return
        }
        enrichmentPending = false
        applyNow(detail: detail, tmdb: tmdb)
        if tmdb.useCollections, let collection {
            // (The film itself left out: the row is the rest of its series.)
            collectionParts = await TMDBService.collectionItems(id: collection.id)
                .filter { $0.id != meta.id }
                .deduplicatedByID()
        }
    }

    /// The TMDB details' sections, at once (the collection's titles are a
    /// request of their own).
    private func applyNow(detail: TMDBService.Detail, tmdb: TMDBSettings) {
        // Granular TMDB toggles gate which enriched sections appear.
        if tmdb.useCredits {
            cast = detail.cast
            crew = detail.crew
            director = detail.director
        }
        if tmdb.useDetails {
            country = detail.country
            language = detail.language
        }
        contentRating = detail.contentRating
        // The toggles gate the facts the same way as the sections.
        var facts = detail.facts
        if !tmdb.useCredits { facts.creatorLine = nil }
        if !tmdb.useDetails { facts.country = nil; facts.language = nil }
        self.facts = facts
        if tmdb.useReleaseDates { releaseDate = detail.releaseDate }
        if tmdb.useMoreLikeThis { moreLikeThis = detail.moreLikeThis.deduplicatedByID() }
        if tmdb.useProductions { companies = detail.companies }
        if tmdb.useDetails { about = detail.about }
        if tmdb.useCollections { collection = detail.collection }
    }

    /// Fetch MDBList source ratings, resolving a tmdb id to imdb first if needed.
    private func loadMDBRatings(settings: MDBListSettings) async -> MDBListRatings? {
        await MDBListService.ratings(for: meta, settings: settings)
    }

    /// Whether to fetch per-episode TMDB extras (ratings / air dates). Set from
    /// the TMDB "Episodes" toggle when the detail loads.
    var useEpisodeExtras = true

    /// Load per-episode ratings + air dates for a season (once, cached).
    func loadSeason(_ season: Int) async {
        guard useEpisodeExtras, episodeExtras[season] == nil, meta.isSeries else { return }
        let extras = await TMDBService.seasonEpisodes(imdbID: meta.id, type: meta.type, season: season)
        if !extras.isEmpty { episodeExtras[season] = extras }
    }

}

struct DetailView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var layout: HomeCatalogSettingsStore
    @AppStorage(DetailHideSpoilers.key) private var hideSpoilers = false
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @StateObject private var viewModel: DetailViewModel

    /// Play: the stage, the first source found on it (`PlayLauncher`), the player.
    @ObservedObject private var launcher = PlayLauncher.shared

    private func play(_ video: MetaVideo?, fromStart: Bool = false) {
        launcher.play(viewModel.meta, video, fromStart: fromStart, art: stageArt(video))
    }

    /// The stage's picture: the episode's TMDB still in full size, else the backdrop.
    private func stageArt(_ video: MetaVideo?) -> String? {
        let extra = video.flatMap { v in v.episode.flatMap { viewModel.episodeExtras[v.season ?? 0]?[$0] } }
        return TMDBService.originalSize(extra?.still) ?? viewModel.backdropURL
    }

    /// Hold Play (or an episode's "Choose Source"): the source list, on the
    /// stage (`SourcePicker`).
    private func openSources(_ video: MetaVideo?) {
        SourcePicker.shared.open(viewModel.meta, video, art: stageArt(video))
    }
    var onSelectItem: (MetaItem) -> Void = { _ in }
    /// The pages opened from here (a person, a studio, a genre, a tag) get
    /// this page's picture (`backdropURL`) as their last argument.
    var onSelectPerson: (Int, String, String?) -> Void = { _, _, _ in }
    var onSelectCompany: (TMDBService.Company, String?) -> Void = { _, _ in }
    /// A genre tag in About: that genre's titles (films or shows, as this one).
    var onSelectGenre: (TMDBService.Genre, Bool, String?) -> Void = { _, _, _ in }
    /// A tag in About: the titles with that keyword (films or shows, as this one).
    var onSelectKeyword: (TMDBService.Keyword, Bool, String?) -> Void = { _, _, _ in }
    /// The trailer over the picture while focus rests on the buttons (as
    /// Home's billboard — Settings → Home & Details → Trailers).
    @StateObject private var trailer = StageTrailer()
    @ObservedObject private var trailerGate = TrailerGate.shared
    @Environment(\.scenePhase) private var detailScenePhase
    /// On screen (not under a page opened from it).
    @State private var pageShown = false
    /// The series' size and status, once loaded (see `FixedFocusShowInfo`).
    @State private var showInfo: TMDBService.ShowSize?
    /// The billboard's one line under the logo (TMDB's tagline; the name
    /// until it's known) — as on Home's billboard.
    @State private var billboardTagline: String?
    /// The action row's controls, for the enter-lands-on-Play redirect.
    private enum ActionControl: Hashable {
        case play, library, info
    }
    /// Entering the action row from ANY direction lands on the Play button:
    /// when focus arrives on any other control while the row didn't previously
    /// hold focus, it's immediately redirected to Play. (`.focusScope`, and
    /// `.defaultFocus` applied to the ROW, both BROKE directional entry into
    /// the row's focusSection on tvOS 26; this manual redirect doesn't. The
    /// `.defaultFocus` on the scroll view in `body` is a different thing —
    /// it only decides the page's OPENING focus, not directional moves.)
    ///
    /// The row's focus state lives with the row (`FocusBridgeHost`) — on the
    /// rows path the row is hosted by the rows engine, a SwiftUI host of its
    /// own, and SwiftUI focus state doesn't reach across hosts. The page
    /// reads and sets it through the bridge, under the same name.
    @State private var actionBridge = FocusBridge<ActionControl>()
    private var actionFocus: ActionControl? {
        get { actionBridge.current }
        nonmutating set { actionBridge.request(newValue) }
    }
    /// (From the billboard: Play lit from the first frame — the swap brought
    /// it in lit; focus lands on it a moment later without a visible change.)
    /// About's content height, as laid out (see `FixedFocusCustomRow.contentHeight`).
    @State private var aboutContentHeight: CGFloat = 0
    /// Info's glass panel (the summary) is open.
    @State private var summaryShown = false
    /// Focus going back onto Info as its panel closes: not redirected to Play.
    @State private var returningToInfo = false
    @State private var litAction: ActionControl? = MainActor.assumeIsolated {
        ModeSwap.shared.billboardItemID != nil ? .play : nil
    }
    /// The title's colours: Episodes / More sit on them (as Home's rows).
    @State private var tint: Color? = MainActor.assumeIsolated {
        ModeSwap.shared.billboardItemID != nil ? ModeSwap.shared.billboardTint.first : nil
    }
    @State private var tintSecond: Color? = MainActor.assumeIsolated {
        ModeSwap.shared.billboardItemID != nil ? ModeSwap.shared.billboardTint.second : nil
    }
    /// The picture blurred, for Episodes / More (nil: none / not yet).
    @State private var blurredBackdrop: UIImage?
    /// Opened from Home's billboard: this page plays its half of the swap
    /// in, and Back plays it out and returns (see `ModeSwap`).
    @State private var fromBillboard: Bool
    /// Built with its data (`DetailPreparer`): nothing to hold back.
    @State private var prepared: Bool
    private let onReturnToBillboard: (() -> Void)?
    /// From a box: the scrim arrives half-way (the growing box took it that
    /// far) and finishes with the page's parts; Back takes it half-way back.
    @State private var scrim: Double
    /// The trailer full screen: its cover, at once…
    @State private var trailerCover = false
    /// …and the page's text, buttons and shade fading out under it.
    @State private var trailerFull = false
    /// The billboard's season count ("3 Seasons") when opened from there.
    /// State, not a plain property: SwiftUI re-creates this view while the
    /// page is up, and only the FIRST creation still sees the handoff.
    @State private var billboardSeriesSize: String?
    /// The backdrop's depth, 0…1 (1 = a step into the title).
    @State private var depth: CGFloat
    /// The season row opens on the Play target's season, once.
    @State private var seasonAutoPicked = false

    /// How Play was pressed while a series' episode list was still loading —
    /// replayed against the real episode the moment it resolves.
    private enum PendingPlay { case auto, manual }
    @State private var pendingSeriesPlay: PendingPlay?

    init(
        item: MetaItem,
        onSelectItem: @escaping (MetaItem) -> Void = { _ in },
        onSelectPerson: @escaping (Int, String, String?) -> Void = { _, _, _ in },
        onSelectCompany: @escaping (TMDBService.Company, String?) -> Void = { _, _ in },
        onSelectGenre: @escaping (TMDBService.Genre, Bool, String?) -> Void = { _, _, _ in },
        onSelectKeyword: @escaping (TMDBService.Keyword, Bool, String?) -> Void = { _, _, _ in },
        onReturnToBillboard: (() -> Void)? = nil,
        takesPrepared: Bool = true
    ) {
        let fromBillboard = MainActor.assumeIsolated { ModeSwap.shared.billboardItemID == item.id }
        let model = DetailViewModel(item: item)
        // Got ready under the curtain (`DetailTransition`): built with it.
        // (Not a Details on its way out: rebuilt as the same title opened
        // again, it took the new one's record — that one came in bare.)
        let prepared = takesPrepared ? MainActor.assumeIsolated { DetailPreparer.shared.take(item.id) } : nil
        if let prepared {
            MainActor.assumeIsolated { model.seed(prepared) }
            _showInfo = State(initialValue: prepared.showInfo)
            _billboardTagline = State(initialValue: prepared.tagline)
        }
        _prepared = State(initialValue: prepared != nil)
        if fromBillboard, prepared == nil {
            // Start with exactly what the billboard showed — nothing in the
            // title block may change as the page takes over.
            MainActor.assumeIsolated {
                model.mdbRatings = ModeSwap.shared.billboardRatings
                model.facts = ModeSwap.shared.billboardFacts
            }
        }
        _viewModel = StateObject(wrappedValue: model)
        _fromBillboard = State(initialValue: fromBillboard)
        _scrim = State(initialValue: 1)
        _depth = State(initialValue: 1)
        _billboardSeriesSize = State(initialValue: fromBillboard
            ? MainActor.assumeIsolated { ModeSwap.shared.billboardSeriesSize } : nil)

        self.onReturnToBillboard = onReturnToBillboard
        self.onSelectItem = onSelectItem
        self.onSelectPerson = onSelectPerson
        self.onSelectCompany = onSelectCompany
        self.onSelectGenre = onSelectGenre
        self.onSelectKeyword = onSelectKeyword
    }

    var body: some View {
        let _ = DetailOpenProbe.note("body")
        ZStack {
            ATVBackground()
            rowsLayer

            // About: full screen over the page, blurred; Back (or Select)
            // closes it, focus back on its button.
            if summaryShown, viewModel.meta.description?.isEmpty == false {
                DetailSummaryPanel(title: viewModel.meta.name,
                                   genres: about.genres.map(\.name).joined(separator: " · "),
                                   summary: viewModel.meta.description ?? "",
                                   facts: about.factsBox(across: 2, width: SummaryPanelMetrics.columnWidth)
                                       .environmentObject(mdblist)) {
                    summaryShown = false
                    returningToInfo = true
                    actionFocus = .info
                }
                .transition(.opacity)
            }

        }
        .animation(Motion.fade, value: summaryShown)
        .task {
            // Dev: -sourcesDemo opens the source panel (the simulator can't hold Play).
            guard ProcessInfo.processInfo.arguments.contains("-sourcesDemo"), !viewModel.meta.isSeries else { return }
            try? await Task.sleep(for: .seconds(2))
            openSources(nil)
        }
        .task {
            // Dev: -focusLog prints the focused item every 2s (sim key
            // delivery is flaky; this is the only reliable focus truth).
            if ProcessInfo.processInfo.arguments.contains("-focusLog") {
                while !Task.isCancelled {
                    let env = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
                    let item = env.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
                    NSLog("[CueFocus] focused=%@ action=%@",
                          item.map { String(describing: $0).prefix(200) }.map(String.init) ?? "NONE",
                          actionFocus.map { String(describing: $0) } ?? "nil")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        .onChange(of: seriesPlayTarget?.id) { _, _ in
            // The episode row opens on the season Play would start.
            if !seasonAutoPicked, let target = seriesPlayTarget {
                seasonAutoPicked = true
                if let season = target.season { viewModel.selectedSeason = season }
            }
            guard let pending = pendingSeriesPlay, let target = seriesPlayTarget else { return }
            pendingSeriesPlay = nil
            switch pending {
            case .auto: play(target)
            case .manual: openSources(target)
            }
        }
        .task {
            // Opened from the billboard: let the swap play first — the load
            // re-renders the whole page as its data lands, and doing that
            // mid-animation dropped frames.
            // (Fetching starts at once; the page only changes once it's over.)
            await viewModel.load(addonManager: addonManager, mdbSettings: mdblist.settings, tmdb: tmdbSettings.settings,
                                 settleUntil: fromBillboard && !prepared
                                    ? Date().addingTimeInterval(ModeSwap.swapSettle + 0.15) : nil)
        }
        .onReceive(viewModel.objectWillChange) { DetailOpenProbe.note("change") }
        .onAppear {
            DetailOpenProbe.note("appear")
            DetailTransition.shared.pageAppeared(viewModel.meta.id)
            guard fromBillboard else { return }
            // Consumed: a title opened from here again is a normal push.
            ModeSwap.shared.billboardItemID = nil
            // A press made while Home handed over: it's this page's.
            if let held = ModeSwap.shared.heldPress {
                ModeSwap.shared.heldPress = nil
                DispatchQueue.main.async { act(held) }
            }
        }
        // Back: a source search stops; below the billboard, up to it (one
        // scroll, focus on Play — the rows keep their places); on it, out
        // (`DetailTransition`). (Read here, not in the body: the depth
        // re-rendering the page made the billboard text lag the rows.)
        .onExitCommand {
            if launcher.searching != nil { launcher.cancel(); return }
            if rowsDepth.depth > 0 {
                rowCommand = FixedFocusRowsCommand(action: .focusBillboard)
                return
            }
            backToBillboard()
        }
        // THE TRAILER: resting on the buttons, it plays over the picture;
        // leaving them, a panel, a search, the player: back to the still.
        // The billboard's trailer, playing on (`DetailTransition.open(trailer:)`).
        .onAppear { pageShown = true; trailer.adopt(viewModel.meta); restTrailer() }
        .task(id: "\(viewModel.meta.id)#\(trailerSeason.season ?? 0)") { await lookUpTrailer() }
        .onDisappear { pageShown = false; trailer.stop() }
        .onChange(of: summaryShown) { _, _ in restTrailer() }
        .onChange(of: launcher.searching) { _, _ in restTrailer() }
        .onChange(of: trailerGate.playerUp) { _, _ in restTrailer() }
        .onChange(of: detailScenePhase) { _, _ in restTrailer() }
        .onChange(of: layout.heroTrailersEnabled) { _, _ in restTrailer() }
        .onChange(of: layout.heroTrailerSound) { _, _ in restTrailer() }
        // Up from the buttons: the trailer on the picture full screen (from
        // its start if none is on), playing on behind once closed.
        // The cover comes and goes at once, clear (the picture under it is
        // the trailer's); what's over the picture fades out and back in.
        .onChange(of: trailer.full) { _, full in
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { trailerCover = full }
            withAnimation(Motion.present) { trailerFull = full }
        }
        .fullScreenCover(isPresented: Binding(get: { trailerCover }, set: { if !$0 { closeFullTrailer() } }),
                         onDismiss: closeFullTrailer) {
            TrailerFullScreen(trailer: trailer, title: viewModel.meta.name, close: closeFullTrailer)
                .ignoresSafeArea()
                .presentationBackground(.clear)
        }
    }

    // MARK: - Details on Home's rows

    private static let billboardRowID = "detail.billboard"
    private static let seasonRowPrefix = "detail.season."
    /// How far below the billboard focus is (the engine's — see `onDepth`).
    /// NOT the page's state: only the views that move with it read it
    /// (`RowsDepthReader`) — a change re-rendered the whole page, and the
    /// billboard text (SwiftUI, animated on the main thread) fell behind
    /// the rows (Core Animation).
    @State private var rowsDepth = DetailRowsDepth()

    /// THE PAGE AS HOME'S ROWS: the billboard (its picture is the engine's;
    /// its text and buttons are a layer on top, moved with it), then a row
    /// per season — moving focus, Continue Watching's cards — then More Like
    /// This and the collection. Down from the buttons is ONE RIGID SCROLL:
    /// the first row waits right under the buttons — its name dim, its cards
    /// hidden — and everything moves up together; the cards fade in on the
    /// way (`FixedFocusRows.rigidRest`). The picture stays, blurred and
    /// dimmed below the overview.
    private var rowsLayer: some View {
        ZStack(alignment: .topLeading) {
            rowsBackdrop
            let seasonIDs: Set<String> = [Self.episodesRowID]
            FixedFocusRows(rows: detailRows, featuredRowID: Self.billboardRowID, continueRowID: "",
                           active: true, progress: [:],
                           // Episodes: landscape tiles (the collections' size —
                           // about 3½ in view), moving focus.
                           landscapeRowIDs: seasonIDs,
                           // The collection, More Like This, Cast & Crew:
                           // moving focus too — posters / portraits, a
                           // caption under each.
                           destinationRowIDs: seasonIDs.union([Self.collectionRowID, Self.moreRowID,
                                                               Self.castRowID, Self.studiosRowID]),
                           // Cast & Crew: smaller portraits — many people.
                           portraitRowIDs: [Self.castRowID],
                           onSelect: onSelectItem,
                           onSelectFeatured: { _ in },
                           onResume: { _ in },
                           titleMenu: { item, rowID in
                               rowID.hasPrefix(Self.seasonRowPrefix)
                                   ? (rowEpisodes.firstIndex { $0.id == item.id }.flatMap { episodeMenu($0)?.entries } ?? [])
                                   // (People: no menu.)
                                   : [Self.castRowID, Self.studiosRowID].contains(rowID) ? []
                                   : TitleMenu.shared.entries(for: item)
                           },
                           onDepth: { rowsDepth.depth = $0 },
                           externalBillboard: true,
                           cardStates: episodeCardStates,
                           onSelectInRow: { item, rowID in
                               // A network or studio: its titles.
                               if rowID == Self.studiosRowID,
                                  let company = viewModel.companies.first(where: { Self.companyItemID($0) == item.id }) {
                                   onSelectCompany(company, viewModel.backdropURL)
                                   return true
                               }
                               // A person: their page (filmography).
                               if rowID == Self.castRowID, item.id.hasPrefix(Self.personPrefix),
                                  let id = Int(item.id.dropFirst(Self.personPrefix.count)) {
                                   onSelectPerson(id, item.name, viewModel.backdropURL)
                                   return true
                               }
                               guard rowID.hasPrefix(Self.seasonRowPrefix) else { return false }
                               if let episode = rowEpisodes.first(where: { $0.id == item.id }) { play(episode) }
                               return true
                           },
                           command: rowCommand,
                           // EXACTLY Home's billboard: the first row waiting
                           // just below the screen, its name at Home's spot,
                           // the billboard going up until its bottom is the
                           // peek.
                           rigidRest: HomeUIKitView.rigidRowRest,
                           rigidNameY: FixedFocusRowsLayout.nextNameY,
                           // The first row's cards peek up the bottom edge,
                           // named as on Home (a show's "Episodes": its season
                           // buttons take the name's place in the row).
                           rigidPeek: Self.episodesPeek,
                           rigidPeekShowsName: true,
                           // Out with the trailer, back as it goes — and in
                           // from Home's playing trailer, never shown before it.
                           peekHidden: trailer.shown || (!pageShown && StageTrailer.carries(viewModel.meta.id)),
                           // Opened in place from Home's billboard: up from
                           // below after the hand-over, down first on Back.
                           followsDetailsArriving: true,
                           hidesBillboardPicture: true,
                           // The season's progress: between the season
                           // buttons and the episodes.
                           rowTitleAccessories: rowProgressAccessory,
                           // The seasons: glass buttons over the episodes (Up
                           // from them); focus on one jumps the row there.
                           rowHeaders: seasonHeader,
                           onHeaderFocus: { _, index in
                               guard rowSeasons.indices.contains(index), rowSeasons[index] != rowSeason else { return }
                               stepSeason(to: rowSeasons[index])
                           },
                           // The billboard's text and buttons: the engine's,
                           // moved with the rows in the same animation.
                           billboardOverlay: rowsBillboardOverlay,
                           billboardOverlayHeight: Self.overlayHeight,
                           rigidBillboardTravel: HomeUIKitView.rigidBillboardTravel,
                           // The episode in focus always at the first card's
                           // spot.
                           anchoredRowIDs: seasonIDs,
                           // About: the summary, facts and ratings, genres and tags.
                           customRows: [Self.aboutRowID: FixedFocusCustomRow(
                               height: Self.aboutHeight,
                               view: aboutBlock,
                               // (Short: About rests just high enough to show it all.)
                               contentHeight: aboutContentHeight > 0 ? aboutContentHeight : nil)],
                           // Network & studios: their logos on light plates.
                           logoRowIDs: [Self.studiosRowID]) { item, position in
                // Up into the billboard lands on its invisible card: on to
                // Play (the billboard's focus is its buttons).
                if position != nil { DispatchQueue.main.async { actionFocus = .play } }
                // The episode in focus (the progress map follows it).
                if item.type == "episode" { focusedRowEpisode = item.id }
            }
            .ignoresSafeArea()
            // Under the full-screen trailer: out, the picture alone.
            .opacity(trailerFull ? 0 : 1)
            // (Again once the episode list is in: opened from a card, the page
            // starts with the card's data — no seasons yet.)
            .task(id: "\(viewModel.meta.id)|\(viewModel.meta.seasons.count)") {
                // Every season's stills, lengths, air dates: the one shown
                // first (with the core load), the rest together in ONE change.
                await viewModel.loadSeasons(viewModel.meta.seasons)
            }
            // The row waits on the episode Play shows: Down lands there.
            .onChange(of: aimKey, initial: true) { _, _ in
                guard focusedRowEpisode == nil, let target = seriesPlayTarget else { return }
                aimRow(at: target.id)
            }
        }
        .ignoresSafeArea()
    }

    /// The episode in focus in the row (nil: none yet).
    @State private var focusedRowEpisode: String?
    /// The episode the row is aimed at (Play's; a season's from the pill).
    @State private var aimedRowEpisode: String?
    @State private var rowCommand: FixedFocusRowsCommand?

    /// THE PICTURE stays: sharp under the overview (the billboard's shade
    /// on it); below it, its blurred copy fades in over it and it steps
    /// back, dimmed — the shade gone (no text there to keep readable): the
    /// rows sit on calm ground of the same picture. (Tried
    /// 2026-10-07: Home's way — the picture going up, the rows on the
    /// title's colour layout; the blur looked better here.)
    private var rowsBackdrop: some View {
        RowsDepthReader(model: rowsDepth) { depth in rowsBackdrop(below: depth > 0) }
    }

    private func rowsBackdrop(below: Bool) -> some View {
        let url = viewModel.backdropURL
        let drift = StagePictureView.drift
        return ZStack {
            TitleTintBackground(tint: tint, second: tintSecond)
                .task(id: url ?? "") {
                    guard let url, let colors = await FixedFocusTint.colors(for: url)
                    else { return }
                    tint = colors.first
                    tintSecond = colors.second
                }
            // EXACTLY where Home's billboard left it (the swap): its size, a
            // little wider than the screen, leaned in by the step-in zoom.
            // Its picture not in yet: the page's background until it is.
            if viewModel.pictureLate { ATVBackground() }
            RemoteImage(url: url, maxDimension: PictureSize.screen, showsPlaceholder: false)
                .frame(width: 1920 + 2 * drift, height: 1080)
                .modifier(DetailLean(depth: depth))
                .frame(width: 1920, height: 1080)
                .clipped()
            // The trailer never leans in: the screen, as on Home, whatever
            // the picture's depth (it's other footage — the still's zoom
            // under it never shows).
            StageTrailerView(trailer: trailer)
                .frame(width: 1920, height: 1080)
            ZStack {
                if let blurredBackdrop {
                    Image(uiImage: blurredBackdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 1920 + 2 * drift, height: 1080)
                }
            }
            .modifier(DetailLean(depth: depth))
            .frame(width: 1920, height: 1080)
            .clipped()
            .opacity(below ? 1 : 0)
            // Below: the dim, more for a bright picture.
            Color.black.opacity(below ? StageArt.dimBelow(for: url) : 0)
            // The billboard's shade, exactly Home's (`StageArt.shade`).
            Group {
                if let shade = StageArt.shade {
                    Image(uiImage: shade).resizable()
                } else {
                    BillboardShade()
                }
            }
            .frame(width: 1920, height: 1080)
            .opacity(below || trailerFull ? 0 : scrim)
        }
        .frame(width: 1920, height: 1080)
        // (On the backdrop itself: an empty view never starts a task. By the
        // picture's address: it arrives after the page opens.)
        .task(id: url ?? "") {
            blurredBackdrop = await BlurredBackdrop.image(for: url)
        }
        // On the rows' own curve and time.
        .animation(FixedFocusMotion.animation(duration: FixedFocusMotion.billboardScroll), value: below)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Where you are in the season, under the season buttons: its ticks,
    /// then "3 of 7".
    private var rowProgressAccessory: [String: AnyView] {
        guard viewModel.meta.isSeries, let episode = rowProgressEpisode else { return [:] }
        let season = episode.season ?? 0
        let all = viewModel.episodes(season: season)
        let done = all.filter { isWatched($0, season: season) }.count
        let map = SeasonProgressMap(ticks: seasonTicks(for: episode), label: "\(done) of \(all.count)",
                                    inline: true, width: SeasonProgressMap.inlineWidth)
            .fixedSize()
        return [Self.episodesRowID: AnyView(map)]
    }

    /// The seasons over the episode row (more than one), the row's own marked.
    private var seasonHeader: [String: FixedFocusRowHeader] {
        let seasons = rowSeasons
        guard seasons.count > 1, let index = rowSeason.flatMap({ seasons.firstIndex(of: $0) }) else { return [:] }
        return [Self.episodesRowID: FixedFocusRowHeader(labels: seasons.map(seasonName), selected: index)]
    }

    private static let episodesRowID = seasonRowPrefix + "all"
    private static let collectionRowID = "detail.collection"
    private static let moreRowID = "detail.more"
    private static let castRowID = "detail.cast"
    private static let aboutRowID = "detail.about"
    /// About's room: from under its name at the rows' spot to the screen's
    /// bottom margin.
    private static var aboutHeight: CGFloat {
        1080 - FixedFocusMetrics.rowTop - FixedFocusMetrics.titleHeight - Spotlight.screenInset
    }
    private static let studiosRowID = "detail.studios"
    private static func companyItemID(_ company: TMDBService.Company) -> String {
        "company:\(company.isNetwork ? "network" : "studio"):\(company.id)"
    }
    private static let personPrefix = "person:"
    /// About this many people in Cast & Crew.
    private static let castCount = 20
    /// Under the billboard: how much of the episodes' cards peeks up.
    private static let episodesPeek: CGFloat = 60

    /// The episodes row: every season in the pill's order (Specials last).
    private var rowItemsInOrder: [EpisodeRowItem] { rowData.ordered }

    /// The season the row is in: its focused episode's, else the aimed one's.
    private var rowSeason: Int? {
        let data = rowData
        let id = focusedRowEpisode ?? aimedRowEpisode
        // (Not yet aimed: Play's season — the row opens there; "Season 1"
        // first would flash.)
        return id.flatMap { data.orderedIndex[$0] }.map { data.ordered[$0].season }
            ?? data.playTarget?.season ?? data.seasons.first
    }

    /// Changes when the row (or Play's episode) does: re-aim.
    private var aimKey: String { "\(rowItemsInOrder.count)-\(seriesPlayTarget?.id ?? "")" }

    private func aimRow(at episodeID: String) {
        guard let index = rowData.orderedIndex[episodeID] else { return }
        aimedRowEpisode = episodeID
        rowCommand = FixedFocusRowsCommand(action: .aim(rowID: Self.episodesRowID, index: index))
    }

    /// A season's way in: its first episode not watched, else its first.
    private func entryEpisode(season: Int) -> EpisodeRowItem? {
        let episodes = rowItemsInOrder.filter { $0.season == season }
        return episodes.first { !$0.state.watched } ?? episodes.first
    }

    /// The seasons, then Specials.
    private var rowSeasons: [Int] { rowData.seasons }

    /// The map's episode: the one in focus, else where the season starts.
    private var rowProgressEpisode: MetaVideo? {
        let id = focusedRowEpisode ?? aimedRowEpisode
        let episodes = rowEpisodes, season = rowSeason
        return episodes.first { $0.id == id } ?? episodes.first { $0.season == season }
    }

    private func stepSeason(to season: Int) {
        guard let entry = entryEpisode(season: season) else { return }
        focusedRowEpisode = nil
        aimRow(at: entry.id)
    }

    /// The billboard's text and buttons, scrolled with its picture (the
    /// engine's own distance, curve and time).
    /// The billboard's text and buttons for the engine to host (its own
    /// SwiftUI host: the page's environment goes along).
    private var rowsBillboardOverlay: AnyView {
        AnyView(rowsBillboardText
            .environmentObject(addonManager)
            .environmentObject(progressStore).environmentObject(library)
            .environmentObject(watched).environmentObject(mdblist)
            .environmentObject(tmdbSettings).environmentObject(layout)
            .environmentObject(playerSettings).environmentObject(profiles))
    }

    /// The engine's host for them reaches down to the buttons and their
    /// captions — no further: it would cover the rows from focus.
    private static var overlayHeight: CGFloat { FixedFocusBillboardText.buttonsY + 130 }

    /// The billboard's text and buttons at their place on the billboard —
    /// the engine moves (and dims) them with the rows.
    private var rowsBillboardText: some View {
        ZStack(alignment: .topLeading) {
            // Home's billboard text exactly (the description under the
            // tagline), on its bottom line, the buttons below.
            FixedFocusBillboardText(item: viewModel.meta, info: showInfo, ratings: ratingsBadges,
                                    tagline: billboardTagline ?? TitleRecords.shared.tagline(viewModel.meta),
                                    logo: viewModel.shownLogo,
                                    lead: AnyView(DetailTrailerHint(model: viewModel, trailer: trailer)))
                .task(id: viewModel.meta.id) {
                    let meta = viewModel.meta
                    await TitleRecords.shared.refresh(meta, [.show, .facts])
                    showInfo = TitleRecords.shared.size(meta)
                    billboardTagline = TitleRecords.shared.tagline(meta)
                }
                .frame(height: FixedFocusBillboardText.bottom, alignment: .bottomLeading)
                .padding(.leading, FixedFocusMetrics.titleInset)
            headerExtras
                .frame(height: TitleBlock.buttonHeight)
                .padding(.top, FixedFocusBillboardText.buttonsY)
        }
        // (Its host's size — see `overlayHeight` — from the screen's top.)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The rows: the billboard, a row per season, More Like This, the collection.
    private var detailRows: [HomeRow] {
        var rows = [HomeRow(id: Self.billboardRowID, title: "", items: [viewModel.meta])]
        if viewModel.meta.isSeries {
            // ONE row: every episode; in the row, the season buttons.
            let data = rowData
            rows.append(HomeRow(id: Self.episodesRowID, title: "Episodes",
                                items: data.rowItems, subtitles: data.subtitles))
        }
        // A film's series first — its next part is the likeliest next watch.
        if let collection = viewModel.collection, !viewModel.collectionParts.isEmpty {
            rows.append(HomeRow(id: Self.collectionRowID, title: collection.name,
                                items: viewModel.collectionParts))
        }
        if !viewModel.moreLikeThis.isEmpty {
            // (Films you've seen last — TMDB's order otherwise.)
            let more = viewModel.moreLikeThis
            let seen = more.filter { watched.isWatched($0) }
            rows.append(HomeRow(id: Self.moreRowID, title: "More Like This",
                                items: more.filter { !watched.isWatched($0) } + seen))
        }
        // The people: creators / director first, then the cast — portraits.
        let people = Array((viewModel.crew + viewModel.cast).prefix(Self.castCount))
        if !people.isEmpty {
            rows.append(HomeRow(
                id: Self.castRowID, title: "Cast & Crew",
                items: people.map { MetaItem(id: "\(Self.personPrefix)\($0.id)", type: "person",
                                             name: $0.name, poster: $0.profileURL) },
                subtitles: Dictionary(people.compactMap { person in
                    person.character.flatMap { $0.isEmpty ? nil : ("\(Self.personPrefix)\(person.id)", $0) }
                }, uniquingKeysWith: { a, _ in a })))
        }
        // The network and studios, by their logos — before About.
        let companies = viewModel.companies
        if !companies.isEmpty {
            rows.append(HomeRow(
                id: Self.studiosRowID,
                title: companies.contains(where: \.isNetwork) ? "Network & Studios" : "Studios",
                items: companies.map { MetaItem(id: Self.companyItemID($0), type: "company", name: $0.name,
                                                poster: $0.logoURL, background: $0.logoURL) }))
        }
        // The page's end: About (a view, not cards — `customRows`).
        if hasAbout {
            rows.append(HomeRow(id: Self.aboutRowID, title: "About", items: []))
        }
        return rows
    }

    /// About has something to say: a description, or TMDB's facts.
    private var hasAbout: Bool {
        viewModel.meta.description?.isEmpty == false || viewModel.about != nil || !viewModel.companies.isEmpty
    }

    /// About: the summary, the facts and ratings, genres and tags (its
    /// facts also in the Summary panel).
    private var about: DetailAbout {
        DetailAbout(meta: viewModel.meta, about: viewModel.about, facts: viewModel.facts,
                    releaseDate: viewModel.releaseDate, contentRating: viewModel.contentRating,
                    language: viewModel.language, ratings: viewModel.mdbRatings,
                    settings: mdblist.settings, studiosShown: !viewModel.companies.isEmpty,
                    crew: viewModel.crew,
                    onSelectGenre: { onSelectGenre($0, !viewModel.meta.isSeries, viewModel.backdropURL) },
                    onSelectKeyword: { onSelectKeyword($0, !viewModel.meta.isSeries, viewModel.backdropURL) },
                    onFocus: { _ in },
                    onContentHeight: { height in
                        if abs(height - aboutContentHeight) > 1 { aboutContentHeight = height }
                    })
    }

    /// About in the rows — with the page's stores.
    private var aboutBlock: AnyView {
        AnyView(about
            // (In line with the row's name.)
            .padding(.leading, FixedFocusMetrics.titleInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environmentObject(mdblist)
            .environmentObject(tmdbSettings).environmentObject(layout))
    }

    /// Each episode's state line on its card (Continue Watching's).
    private var episodeCardStates: [String: FixedFocusCardState] { rowData.cardStates }

    /// The billboard's buttons.
    private var headerExtras: some View {
        // The row with its own focus state (see `actionFocus`); Play is the
        // default.
        FocusBridgeHost(bridge: actionBridge, defaultValue: .play,
                        onChange: { old, new in actionFocusChanged(from: old, to: new) }) { focus in actionRow(focus) }
            // (The billboard's column.)
            .padding(.leading, FixedFocusMetrics.titleInset)
    }

    /// A Select, Back or Down made during the swap (`ModeSwap.heldPress`).
    private func act(_ held: ModeSwap.HeldPress) {
        switch held {
        case .play:
            let target = viewModel.meta.isSeries ? seriesPlayTarget : nil
            if viewModel.meta.isSeries, target == nil { pendingSeriesPlay = .auto }
            else { play(target) }
        case .back:
            backToBillboard()
        case .down:
            // (The rows take Down themselves.)
            break
        }
    }

    /// Resting on the buttons, nothing over the page: the trailer may
    /// play (after the rest's delay); else back to the still.
    private func restTrailer() {
        guard !trailer.full else { return }
        let resting = pageShown && actionBridge.current != nil && !summaryShown
            && launcher.searching == nil && !trailerGate.playerUp
            && detailScenePhase == .active && layout.heroTrailersEnabled
        if resting {
            let about = trailerSeason
            trailer.rest(on: viewModel.meta, season: about.season, aired: about.aired,
                         sound: layout.heroTrailerSound)
        } else {
            trailer.pause()
        }
    }

    /// A show: the row's season (where Play goes) — its first episode's
    /// date too: TMDB numbers seasons its own way.
    private var trailerSeason: (season: Int?, aired: Date?) {
        let season = viewModel.meta.type == "movie" ? nil : rowSeason
        let aired = season.flatMap { season in
            viewModel.meta.videos?.filter { $0.season == season }.compactMap(\.airedDate).min()
        }
        return (season, aired)
    }

    /// The trailer full screen: the one on the picture, where it is, else
    /// the title's from its start. Only once one is known to play.
    private func openFullTrailer() {
        guard viewModel.trailerReady || trailer.shown else { return }
        let about = trailerSeason
        trailer.playFull(on: viewModel.meta, season: about.season, aired: about.aired)
    }

    /// Whether a trailer will play (the row's season's, else the show's):
    /// resolved ahead — kept, so it costs nothing when it plays.
    private func lookUpTrailer() async {
        let about = trailerSeason
        let keys = await TMDBService.trailerKeys(id: viewModel.meta.id, type: viewModel.meta.type,
                                                 season: about.season, aired: about.aired)
        let found = keys.isEmpty ? nil : await TrailerResolver.prepare(candidates: keys)
        guard !Task.isCancelled else { return }
        let ready = found != nil
        if viewModel.trailerReady != ready {
            withAnimation(.easeInOut(duration: Motion.fadeDuration)) { viewModel.trailerReady = ready }
        }
    }

    private func closeFullTrailer() {
        trailer.leaveFull(resting: layout.heroTrailersEnabled && detailScenePhase == .active,
                          sound: layout.heroTrailerSound)
        restTrailer()
    }

    private func backToBillboard() {
        // Out to Home: its billboard takes the trailer on (`adopt`).
        if onReturnToBillboard != nil { trailer.handOver(within: 1) }
        onReturnToBillboard?()
    }

    /// The title block's ratings row (nil = none).
    private var ratingsBadges: AnyView? {
        FixedFocusBillboardText.ratingsChips(viewModel.mdbRatings, settings: mdblist.settings,
                                             item: viewModel.meta, onDetails: true)
    }

    /// Play, Library, About; Up: the trailer full screen (`openFullTrailer`).
    /// Its own focus section so Down/Up move cleanly to/from the rows below
    /// instead of the focus engine skipping a row.
    private func actionRow(_ focus: FocusState<ActionControl?>.Binding) -> some View {
            HStack(spacing: CueSpacing.md) {
                // Play is present from the FIRST frame, even before the
                // episode list has loaded and `seriesPlayTarget` can say
                // which episode it starts (a page without it let focus
                // settle elsewhere, then jumped). Pressing it early is not
                // lost: `pendingSeriesPlay` fires once the target lands.
                //
                let target = viewModel.meta.isSeries ? seriesPlayTarget : nil
                // "Play" — a show's episode under it while focused (a film:
                // nothing).
                DetailActionButton(
                    icon: "play.fill", title: "Play",
                    isPrimary: true, lit: litAction == .play,
                    caption: target.map(seriesPlayTitle),
                    action: {
                        if viewModel.meta.isSeries, target == nil { pendingSeriesPlay = .auto }
                        else { play(target) }
                    },
                    // Hold Select: straight to the source list.
                    onHold: {
                        if viewModel.meta.isSeries, target == nil { pendingSeriesPlay = .manual }
                        else { openSources(target) }
                    },
                    other: .init(title: "Details", icon: "info.circle")
                )
                .focused(focus, equals: .play)
                // The other two are one focus section, so a vertical move
                // into the row resolves against the section as a unit
                // instead of picking whichever circle's centre is nearest
                // (tvOS picks a Down/Up target by horizontal CENTRE distance;
                // a bare circle used to beat Play and flash focus there
                // before the row's redirect pulled it back).
                HStack(spacing: CueSpacing.md) {
                    let saved = library.contains(viewModel.meta)
                    DetailActionButton(
                        icon: saved ? "checkmark" : "plus",
                        title: saved ? "In Library" : "Library",
                        isPrimary: false, lit: litAction == .library, bare: true,
                        // No toast: the button itself says it ("In Library").
                        action: { library.toggle(viewModel.meta) },
                        other: .init(title: saved ? "In Library" : "Library", icon: saved ? "checkmark" : "plus")
                    )
                    .focused(focus, equals: .library)
                    // About in place, over the page (the billboard
                    // shows only the tagline).
                    DetailActionButton(
                        icon: "text.alignleft", title: "About",
                        isPrimary: false, lit: litAction == .info, bare: true,
                        action: {
                            if viewModel.meta.description?.isEmpty == false { summaryShown = true }
                            else { ToastCenter.shared.show("No summary for this title", icon: "text.alignleft") }
                        },
                        other: .init(title: "Next", icon: "chevron.right", plain: true)
                    )
                    .focused(focus, equals: .info)
                }
                .focusSection()
                Spacer(minLength: 0)
            }
            .padding(.top, CueSpacing.xs)
            // Up from the buttons (nothing above them): the trailer full
            // screen — the hint over the logo says so.
            .onMoveCommand { if $0 == .up, !rowsDepth.upEaten() { openFullTrailer() } }
            // Full-width focus section: the buttons stay left-aligned, but the
            // section spans the row so pressing Up from a right-scrolled cast
            // card still lands here (a narrow left-only section is missed when
            // the card below is scrolled far right).
            .frame(maxWidth: .infinity, alignment: .leading)
            // NO .focusSection() here: a programmatic `actionFocus = .play`
            // from OUTSIDE a focus section is silently ignored on tvOS 26,
            // which broke the teaser's direct Down-to-Play jump. Reachability
            // from below is covered by the entry redirect instead.
            //
            // The circle buttons are ALWAYS focusable. They used to carry
            // `.focusable(actionFocus != nil)` so that entering the row could
            // only land on Play — but that makes the focusable SET depend on
            // focus itself: pressing Down on the synopsis set actionFocus,
            // which re-rendered the row and flipped the circles to focusable
            // mid-move, so the focus engine invalidated and bounced focus back
            // up to the synopsis. Never gate focusability on focus state.
    }

    /// The button row's focus moved (from `FocusBridgeHost`, as it happens).
    /// Only what changes is set: a page-wide redraw per press is what made
    /// Left / Right feel slow.
    /// - The enter-lands-on-Play redirect: focus arriving on any control
    ///   while the row previously held NOTHING gets moved to Play. Moves
    ///   WITHIN the row (old != nil) are left alone.
    private func actionFocusChanged(from old: ActionControl?, to new: ActionControl?) {
        // The trailer plays on between the buttons; leaving them, it fades out.
        restTrailer()
        // (Back from Info's panel: on Info, as asked — once.)
        if new == .info, returningToInfo { returningToInfo = false; return }
        if old == nil, let new, new != .play {
            // DEFERRED, not immediate: setting @FocusState while the
            // engine's own move is still in flight made it revert —
            // Down from the synopsis went circle -> Play -> back to the
            // synopsis, so the press appeared to do nothing at all.
            Task { @MainActor in
                guard actionFocus != nil, actionFocus != .play else { return }
                actionFocus = .play
            }
        }
    }

    /// For a series, the episode the Play button should start: an in-progress
    /// episode, else the next-up episode, else the very first — like the APK.
    private var seriesPlayTarget: MetaVideo? { rowData.playTarget }

    /// The Play button's label on a show: just the episode ("S1:E1") — the
    /// ▶ says play; resume or not, it continues where you are.
    private func seriesPlayTitle(_ episode: MetaVideo) -> String {
        "S\(episode.season ?? 1):E\(episode.episode ?? 1)"
    }

    // MARK: - Episode row

    /// What the row shows: the specials, then every regular episode in play
    /// order — ONE row, a season seam between each (Left from S1:E1 crosses
    /// into the specials).
    private var rowEpisodes: [MetaVideo] { rowData.episodes }

    /// The episode row, built ONCE until the episode list, the season extras,
    /// progress or watched change. (Built per use, per body pass — and per
    /// episode in one lookup — One Piece's 1,100 episodes froze the page for
    /// seconds, and every focus move in the row rebuilt it.)
    private var rowData: DetailRowData {
        let key = DetailRowData.Key(meta: viewModel.metaRevision, extras: viewModel.extrasRevision,
                                    progress: progressStore.revision, watched: watched.revision,
                                    hideSpoilers: hideSpoilers)
        if let memo = viewModel.rowMemo, memo.key == key { return memo }
        let regular = viewModel.allEpisodesInPlayOrder
        let specials = regular.contains { $0.season == 0 } ? [] : viewModel.episodes(season: 0)
        let episodes = specials + regular
        let items = buildEpisodeRowItems(episodes)
        let seasons = viewModel.meta.seasons.sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
        let order = Dictionary(seasons.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = items.enumerated().sorted {
            (order[$0.element.season] ?? .max, $0.offset) < (order[$1.element.season] ?? .max, $1.offset)
        }.map(\.element)
        let data = DetailRowData(
            key: key, episodes: episodes, items: items, ordered: ordered,
            orderedIndex: Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }),
            seasons: seasons,
            playTarget: SeriesEpisodes.playTarget(viewModel.meta.id, in: regular,
                                                  progress: progressStore, watched: watched),
            cardStates: Dictionary(items.map { item in
                (item.id, FixedFocusCardState(label: item.state.label, fraction: item.state.progress,
                                              right: item.state.remaining.map { "\($0) left" } ?? item.state.status,
                                              // Hide spoilers: not watched or started — its still blurred.
                                              blurred: hideSpoilers && !item.state.watched && item.state.progress == nil))
            }, uniquingKeysWith: { a, _ in a }),
            rowItems: ordered.map { MetaItem(id: $0.id, type: "episode", name: $0.title, background: $0.image) },
            subtitles: Dictionary(ordered.map { ($0.id, $0.facts) }, uniquingKeysWith: { a, _ in a }))
        viewModel.rowMemo = data
        return data
    }

    private func buildEpisodeRowItems(_ episodes: [MetaVideo]) -> [EpisodeRowItem] {
        episodes.map { episode in
            let season = episode.season ?? 0
            let extra = episode.episode.flatMap { viewModel.episodeExtras[season]?[$0] }
            // TMDB's still in full resolution first: the add-on's thumbnail is
            // often small, and these cards are big.
            let image = TMDBService.originalSize(extra?.still) ?? episode.thumbnail
                ?? viewModel.backdropURL
            let progress = progressStore.progress(for: episode.id)
            let fraction = progress?.fraction ?? 0
            let done = isWatched(episode, season: season)
            let inProgress = !done && progress?.isStarted == true
            let air = viewModel.airInfo(episode)
            let state = EpisodeRowState(
                label: "S\(season):E\(episode.episode ?? 0)",
                progress: inProgress ? fraction : nil,
                remaining: progress?.remainingTimeText,
                status: done ? "Watched" : (air.countdown ?? episodeLength(episode, extra: extra)),
                watched: done)
            // (Not its length: the card's state line in the box shows it.)
            let facts = air.text ?? ""
            return EpisodeRowItem(
                id: episode.id, season: season, number: episode.episode ?? 0,
                title: episode.title.flatMap { $0.isEmpty ? nil : $0 }
                    ?? episode.episode.map { "Episode \($0)" } ?? "Episode",
                facts: facts,
                image: image,
                state: state)
        }
    }

    /// The progress map's ticks: the focused episode's season.
    private func seasonTicks(for episode: MetaVideo) -> [SeasonProgressMap.Tick] {
        let season = episode.season ?? 0
        return viewModel.episodes(season: season).map { item in
            SeasonProgressMap.Tick(id: item.id, watched: isWatched(item, season: season),
                                   current: item.id == episode.id)
        }
    }

    /// Holding Select on an episode: its menu.
    private func episodeMenu(_ index: Int) -> (title: String, entries: [MenuEntry])? {
        let list = rowEpisodes
        guard list.indices.contains(index) else { return nil }
        let episode = list[index]
        let season = episode.season ?? 0
        var entries: [MenuEntry] = []
        let started = progressStore.progress(for: episode.id)?.isStarted ?? false
        entries.append(MenuEntry(title: started ? "Resume" : "Play", icon: "play.fill") { play(episode) })
        if started {
            entries.append(MenuEntry(title: "Start Over", icon: "gobackward") {
                play(episode, fromStart: true)
            })
        }
        entries.append(MenuEntry(title: "Choose Source", icon: "list.and.film") { openSources(episode) })
        let done = isWatched(episode, season: season)
        entries.append(MenuEntry(title: done ? "Mark as Unwatched" : "Mark as Watched",
                                 icon: done ? "eye.slash" : "checkmark.circle") {
            toggleWatched(episode, season: season)
        })
        if let at = viewModel.allEpisodesInPlayOrder.firstIndex(where: { $0.id == episode.id }), at > 0 {
            entries.append(MenuEntry(title: "Mark Earlier Episodes as Watched", icon: "checklist") {
                markWatched(Array(viewModel.allEpisodesInPlayOrder[..<at]))
            })
        }
        let part = season == 0 ? "Specials" : "Season \(season)"
        let aired = viewModel.episodes(season: season).filter(\.hasAired)
        if !aired.isEmpty, aired.allSatisfy({ isWatched($0, season: season) }) {
            entries.append(MenuEntry(title: "Mark \(part) as Unwatched", icon: "eye.slash") {
                watched.remove(keys: aired.map {
                    WatchedItem.key(contentID: viewModel.meta.id, season: $0.season ?? season, episode: $0.episode)
                })
            })
        } else {
            entries.append(MenuEntry(title: "Mark \(part) as Watched", icon: "checkmark.circle.fill") {
                markSeasonWatched(season)
            })
        }
        return ("\(episode.seasonEpisodeCode) · \(episode.title ?? viewModel.meta.name)", entries)
    }

    /// Episode length: TMDB's runtime for the episode, else the length the
    /// player measured if you've started it, else the show's usual runtime.
    private func episodeLength(_ episode: MetaVideo, extra: TMDBService.EpisodeExtra?) -> String? {
        var minutes = extra?.runtime ?? 0
        if minutes == 0, let duration = progressStore.progress(for: episode.id)?.durationSeconds,
           duration.isFinite, duration > 60 {
            minutes = Int((duration / 60).rounded())
        }
        if minutes > 0 {
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        }
        return viewModel.meta.runtimeFormatted
    }

    private func seasonName(_ season: Int) -> String {
        season == 0 ? "Specials" : "Season \(season)"
    }

    /// Mark every AIRED episode of a season watched (unaired ones would
    /// wreck the new-episode badge).
    private func markSeasonWatched(_ season: Int) {
        markWatched(viewModel.episodes(season: season))
    }

    /// Mark these episodes watched — the aired ones not yet marked.
    private func markWatched(_ episodes: [MetaVideo]) {
        for episode in episodes where episode.hasAired && !watched.isWatched(
            contentID: viewModel.meta.id, season: episode.season ?? 0, episode: episode.episode
        ) {
            watched.mark(meta: viewModel.meta, video: episode)
        }
    }

    private func isWatched(_ episode: MetaVideo, season: Int) -> Bool {
        watched.isWatched(contentID: viewModel.meta.id,
                          season: episode.season ?? season,
                          episode: episode.episode)
    }

    /// Flip one episode's watched state from the hold menu.
    private func toggleWatched(_ episode: MetaVideo, season: Int) {
        if isWatched(episode, season: season) {
            watched.remove(contentID: viewModel.meta.id,
                           season: episode.season ?? season,
                           episode: episode.episode)
        } else {
            watched.mark(meta: viewModel.meta, video: episode)
        }
    }

}

/// A Detail button. The primary one (Play / Resume) always shows its icon
/// and title; the others are circles with an icon — and, focused, a small
/// caption under them. Nothing ever changes
/// size: focus only lights a button up. The top bar's materials
/// (`GlassPill`): glass at rest, the bright highlight focused. `onHold`:
/// holding Select for half a second runs it instead of the action (a press
/// that became a hold never also taps).
struct DetailActionButton: View {
    let icon: String
    let title: String
    let isPrimary: Bool
    let lit: Bool
    /// The primary button's line under it while focused (a show's episode).
    var caption: String? = nil
    /// Only its icon (its name under it while focused) — all but Play.
    var bare = false
    /// Nothing behind it at rest (the billboard's Next).
    var plain = false
    var iconSize = DetailActionButton.iconSize
    /// Home's billboard button: dimmed after its press into Details in
    /// place (`BillboardOpening.focusDimmed`) — pressing it no longer
    /// possible — back to full with Home's parts on Back.
    var billboard = false
    let action: () -> Void
    var onHold: (() -> Void)? = nil
    /// Holding Select opens this menu instead (the billboard's Details:
    /// Play, Choose Source).
    var holdEntries: [MenuEntry]? = nil
    /// Into / out of Details in place: the other page's button in this
    /// place, worn until the second phase — Details' buttons wear Home's
    /// while its parts are held out (`detailsArriving`), becoming Details'
    /// with its peek and hint (Details → Play, › → About); on Back Home's
    /// wear Details' (`BillboardOpening.homeWearsDetails`), becoming
    /// Home's with its parts.
    var other: Other? = nil
    struct Other {
        let title: String
        let icon: String
        var plain = false
    }

    /// Its hold menu open (Play).
    @State private var held = false
    /// Lit by ITS OWN focus (a press redraws this button alone — the page's
    /// `lit` reached it late: through the page's redraw, and across the rows'
    /// SwiftUI host). `lit` only until focus first comes or goes (the swap's
    /// Play, lit from the first frame).
    @State private var focusLit = false
    @State private var focusKnown = false
    private var opening = BillboardOpening.shared
    private var shownLit: Bool { focusKnown ? focusLit : lit }
    /// The other page's button worn (`other`).
    private var worn: Other? {
        guard let other else { return nil }
        let wears = billboard ? opening.homeWearsDetails : opening.detailsArriving && !opening.closing
        return wears ? other : nil
    }
    private var shownTitle: String { worn?.title ?? title }
    /// In place, dimmed until the second phase ends — pressing not
    /// possible: Details' while its parts are held out (coming in, and
    /// from Back's start), Home's from the press until its parts are back.
    private var openingDimmed: Bool {
        billboard ? opening.focusDimmed : other != nil && opening.detailsArriving
    }
    /// Kept pressed while dimmed — the focused one (the one pressed; the
    /// others shrank with it), only into Details (Back presses no button).
    private var keptPressed: Bool { shownLit && openingDimmed && !opening.closing }
    private var shownIcon: String { worn?.icon ?? icon }

    /// Its focus came or went: lit / unlit AT ONCE — the old button and the
    /// new one change together, on one curve (`open`). (A 50 ms wait before
    /// lighting left a moment with nothing lit: it read as lag.)
    private func focusChanged(_ focused: Bool) {
        focusKnown = true
        focusLit = focused
    }

    /// The look is `ActionFace`: a glass pill at rest, a white capsule
    /// when focused. (Tried and dropped: a thin frost, too see-through over
    /// the billboard's bright pictures; a dark fill at rest — grey, black,
    /// black with a light edge; nothing at rest.)
    static let height: CGFloat = 64
    static let focusFill = Color.white
    static let restContent = Color.white.opacity(FixedFocusText.primary)
    /// Inside the capsule, either side (the season buttons).
    static let textPadding: CGFloat = 22
    /// A labelled button's name alone, either side.
    static let labelPadding: CGFloat = 34
    /// The content: text and icons one size (the ⓘ larger — its circle
    /// reads small).
    static let textSize: CGFloat = 26
    /// A name's width at the label's font (the label's width while one
    /// name crossfades into another).
    static func labelWidth(_ title: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: textSize, weight: .semibold)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }
    static let iconSize: CGFloat = 26
    static let iconBox: CGFloat = 30
    /// Lighting up / the caption coming in / the scale: a no-bounce spring.
    static let open: Animation = .spring(duration: 0.15, bounce: 0)
    /// Into / out of Details in place (`openingDimmed`): the highlight's
    /// share — "pressing not possible". In from the release (the press's
    /// shrink done), out with the second phase's move.
    static let dimmedHighlight: Double = 0.5
    static let dim: Animation = .easeInOut(duration: 0.2)
    /// Focus leaving: the capsule shrinks into the button (to `leaveScale`
    /// of it) as it fades — slower than it came, so it's seen going; the
    /// fade goes evenly with the shrink, from the start (a delayed fade
    /// overlapped the next button's capsule).
    static let leave: Animation = .spring(duration: 0.35, bounce: 0)
    static let leaveFade: Animation = .linear(duration: 0.35)
    static let leaveScale: CGFloat = 0.88
    private var litAnimation: Animation { shownLit ? Self.open : Self.leave }
    /// Focused: this much larger.
    static let focusScale: CGFloat = 1.05
    /// Pressed: back to its resting size, level with the other buttons
    /// (quick, `pressIn`), then up again (`pressOut`, a no-bounce spring).
    /// (Tried: 90 % of the focused size — smaller than the buttons beside it.)
    static let pressInTime: Double = 0.1
    static let pressIn: Animation = .easeOut(duration: pressInTime)
    static let pressOut: Animation = .spring(duration: 0.3, bounce: 0)
    /// The caption: small, under the circle.
    static let captionSize: CGFloat = 20
    static let captionGap: CGFloat = 12

    var body: some View {
        // (Not when its hold menu just opened: the release still reached
        // the button — Details opened under the menu.)
        // (Back's scroll up to these buttons running: dropped.)
        Button(action: { if !held, !FixedFocusRowsController.backScrolling { action() } }) {
            HStack(spacing: 10) {
                // A labelled button: its name alone; an icon button: its icon.
                if bare {
                    Image(systemName: shownIcon)
                        .font(.system(size: iconSize, weight: .bold))
                        // (Into Details in place: › becomes About's;
                        // set from another host — no transaction.)
                        .contentTransition(["plus", "checkmark"].contains(shownIcon)
                            ? .symbolEffect(.replace.downUp.byLayer, options: .nonRepeating)
                            : .opacity)
                        .animation(Motion.move, value: shownIcon)
                        .frame(width: Self.iconBox, height: Self.iconBox)
                } else {
                    // (Into Details in place: Details becomes Play — the
                    // two names crossfade, centred, as the width goes from
                    // one to the other; the text's own content transition
                    // kept the old name left-aligned, cut off.)
                    ZStack {
                        Text(shownTitle)
                            .font(.system(size: Self.textSize, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .id(shownTitle)
                            .transition(.opacity)
                    }
                    .frame(width: Self.labelWidth(shownTitle))
                    // (Set from another host — no transaction reaches it.)
                    .animation(Motion.move, value: shownTitle)
                }
            }
            .padding(.horizontal, bare ? 0 : Self.labelPadding)
            .frame(width: bare ? Self.height : nil, height: Self.height)
            .modifier(ActionFace(lit: shownLit, pill: !(worn?.plain ?? plain), dimmed: openingDimmed))
            .animation(Motion.move, value: worn?.plain ?? plain)
            // Under it while focused (outside its frame: the row never moves
            // for it): a show's episode, the bare button's name.
            .overlay(alignment: .top) {
                if let text = isPrimary ? caption : bare ? shownTitle : nil {
                    Text(text)
                        .font(.system(size: Self.captionSize, weight: .medium))
                        .foregroundStyle(AppGlass.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(shownLit ? 1 : 0)
                        .animation(litAnimation, value: shownLit)
                        // (Play's episode comes with Play.)
                        .opacity(isPrimary && worn != nil ? 0 : 1)
                        .animation(Motion.move, value: worn != nil)
                        .offset(y: Self.height + Self.captionGap)
                }
            }
        }
        .buttonStyle(DetailPressStyle(lit: shownLit, held: held, dimmed: keptPressed, onFocus: focusChanged))
        // Hold Select (Play): straight to its sources — through `HoldMenu`
        // (the press is cancelled: no Play on release), no menu.
        .holdMenu(focused: shownLit && (onHold != nil || holdEntries != nil), direct: holdEntries == nil,
                  onHeld: { held = $0 }) {
            holdEntries ?? onHold.map { [MenuEntry(title: "Choose Source", icon: "list.bullet", run: $0)] } ?? []
        }
    }
}

/// THE ACTION BUTTONS' FACE (Details' and the billboard's buttons,
/// Details' season buttons): at rest a glass pill (`pill`; without it,
/// the content with the text's small shadow); focused, a white capsule, dark
/// content; leaving, the capsule shrinks into the button as it fades
/// (`DetailActionButton.leave`, `leaveFade`).
extension EnvironmentValues {
    /// Drawn into an image (the billboard's buttons going out with their
    /// card): the glass pill as a flat stand-in — glass can't be drawn.
    @Entry var actionFaceStill = false
    /// A tab switch: how far Home's background picture still has to drift
    /// (`CueApp.arrive`).
    @Entry var tabPictureShift: CGFloat = 0
}

struct ActionFace: ViewModifier {
    @Environment(\.actionFaceStill) private var still
    let lit: Bool
    var rest: Color = DetailActionButton.restContent
    /// At rest on the glass pill; false: nothing behind it (the billboard's
    /// Next, a season not shown).
    var pill = true
    /// The pill as the current one of a set (the row's season): the flat
    /// light grey (`FlatControl.selected`), not the glass.
    var current = false
    /// Its highlight dimmed (into / out of Details in place) — at
    /// `DetailActionButton.dimmedHighlight`.
    var dimmed = false
    /// With nothing behind it at rest: a soft shadow under the content (over
    /// pictures); false: none (the top bar's words).
    var restShadow = true
    /// Coming in, and going (its shrink and its fade): the buttons' unless
    /// given (the top bar's are quicker).
    var open = DetailActionButton.open
    var leave = DetailActionButton.leave
    var leaveFade = DetailActionButton.leaveFade

    /// A flat pill's edge (the still's, Search's): a faint light edge
    /// brighter along the top.
    static let pillEdge = LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                         startPoint: .top, endPoint: .bottom)

    func body(content: Content) -> some View {
        content
            .foregroundStyle(lit ? FlatControl.contentOnFocus : rest)
            .shadow(color: .black.opacity(lit || pill || !restShadow ? 0 : 0.35), radius: 4, y: 2)
            // The pill under, the focus capsule over it (shrinking into it).
            .background {
                ZStack {
                    // (Faded, not added / removed: a pill popping in or out
                    // flickered.)
                    if current {
                        Capsule().fill(FlatControl.selected).opacity(pill ? 1 : 0)
                    } else {
                        ZStack {
                            if still {
                                Capsule().fill(Color.white.opacity(0.18))
                                Capsule().strokeBorder(Self.pillEdge, lineWidth: 1)
                            } else {
                                // (The glass has its own edge.)
                                Color.clear.liquidGlass(in: Capsule())
                            }
                        }
                        // (Coming in, it grows into the button: into Details
                        // in place, the billboard's › becoming About.)
                        .scaleEffect(pill ? 1 : DetailActionButton.leaveScale)
                        .opacity(pill ? 1 : 0)
                    }
                    Capsule().fill(DetailActionButton.focusFill)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                        // Shrinking only into nothing: over a resting pill it
                        // stays its size — one pill changing colour (shrunk,
                        // two pills showed, one inside the other).
                        .scaleEffect(lit || pill ? 1 : DetailActionButton.leaveScale)
                        .opacity(lit ? 1 : 0)
                        .animation(lit ? open : leaveFade, value: lit)
                        .opacity(dimmed ? DetailActionButton.dimmedHighlight : 1)
                        .animation(dimmed ? DetailActionButton.dim : Motion.move, value: dimmed)
                }
            }
            .animation(lit ? open : leave, value: lit)
    }
}

/// The buttons' size — the cards' rule: focused larger (a scale: a cheap
/// transform), pressed 3 % less, a little more while its hold menu is open.
private struct DetailPressStyle: ButtonStyle {
    let lit: Bool
    let held: Bool
    /// Into / out of Details in place: kept pressed while dimmed (the
    /// press doesn't grow back), growing back with the second phase.
    var dimmed = false
    /// The button's own focus, as it comes and goes.
    var onFocus: (Bool) -> Void = { _ in }
    static let focusScale = DetailActionButton.focusScale

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, lit: lit, held: held, dimmed: dimmed, onFocus: onFocus)
    }

    private struct PressBody: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: Configuration
        let lit: Bool
        let held: Bool
        let dimmed: Bool
        let onFocus: (Bool) -> Void
        /// Shown pressed: from the press on, for at least `pressIn`'s
        /// time (a quick tap still shrinks all the way), then grows back.
        @State private var down = false
        @State private var downAt = Date.distantPast
        @State private var releasing = false

        var body: some View {
            let base = lit ? DetailPressStyle.focusScale : 1
            let scale = held ? base + FixedFocusMetrics.heldGrowth
                : down || dimmed ? 1 : base
            return configuration.label
                .scaleEffect(scale)
                // (Dimmed, as the highlight; undimmed, on the move.)
                .animation(dimmed ? DetailActionButton.dim : Motion.move, value: dimmed)
                // A press: quick in, back on a spring; focus: with the
                // highlight, on its curve.
                .animation(down ? DetailActionButton.pressIn
                           : releasing ? DetailActionButton.pressOut
                           : lit ? DetailActionButton.open : DetailActionButton.leave,
                           value: scale)
                .onChange(of: isFocused) { _, now in onFocus(now) }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed {
                        downAt = .now
                        releasing = false
                        down = true
                        return
                    }
                    let left = DetailActionButton.pressInTime - Date.now.timeIntervalSince(downAt)
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, left)) {
                        releasing = true
                        down = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { releasing = false }
                    }
                }
        }
    }
}

/// The episode row as `DetailView` built it, kept on its view model until
/// one of the inputs in `key` changes.
struct DetailRowData {
    struct Key: Equatable {
        var meta: Int, extras: Int, progress: Int, watched: Int, hideSpoilers: Bool
    }
    let key: Key
    /// Specials first, then every regular episode in play order.
    let episodes: [MetaVideo]
    let items: [EpisodeRowItem]
    /// The row's order: the seasons, Specials last.
    let ordered: [EpisodeRowItem]
    let orderedIndex: [String: Int]
    let seasons: [Int]
    let playTarget: MetaVideo?
    let cardStates: [String: FixedFocusCardState]
    let rowItems: [MetaItem]
    let subtitles: [String: String]
}

/// What happens after a press opens Details (LAN log, "details"): each body
/// pass and view-model change, in ms since the press — for the Home →
/// Details transition work (docs/LOADING-PLAN.md §5).
@MainActor
enum DetailOpenProbe {
    static var pressedAt: CFTimeInterval = 0
    private static var counts: [String: Int] = [:]
    static func pressed() {
        pressedAt = CACurrentMediaTime()
        counts = [:]
        PlayerProbe.event("details", "press")
    }
    static func note(_ what: String) {
        let ms = (CACurrentMediaTime() - pressedAt) * 1000
        guard pressedAt > 0, ms < 4000 else { return }
        counts[what, default: 0] += 1
        PlayerProbe.event("details", String(format: "%@ #%d at %.0f ms", what, counts[what]!, ms))
    }
}

/// The picture Details and the billboard show: the title's TMDB backdrop
/// (`TMDBService.backdrop`), decoded as focus settles on the title, so the
/// press finds it in. Posters and the fixed box keep the add-ons' pictures.
@MainActor
final class TitlePictures {
    static let shared = TitlePictures()

    /// Asked once a launch ("": TMDB has none).
    private var pictures: [String: String] = [:]
    /// Each title's next opening's picture, being decoded / decoded.
    private var decoded: [String: Task<String?, Never>] = [:]

    /// The title's picture (nil: TMDB has none).
    func picture(for item: MetaItem) async -> String? {
        if let url = pictures[item.id] { return url.isEmpty ? nil : url }
        let url = await TMDBService.backdrop(id: item.id, type: item.type)
        pictures[item.id] = url ?? ""
        return url
    }

    /// Focus settled on `item`: its picture, decoded.
    func focused(_ item: MetaItem) {
        guard TMDBService.hasAPIKey, item.type == "movie" || item.type == "series" else { return }
        if decoded[item.id] == nil { decoded[item.id] = decode(item) }
    }

    /// The picture for this opening (nil: TMDB has none — the card's then).
    func forOpening(_ item: MetaItem) -> Task<String?, Never> {
        decoded.removeValue(forKey: item.id) ?? decode(item)
    }

    private func decode(_ item: MetaItem) -> Task<String?, Never> {
        Task { @MainActor in
            guard let url = await self.picture(for: item),
                  await ImageCache.shared.preload(url, maxDimension: PictureSize.screen)
            else { return nil }
            return url
        }
    }
}

/// From the press until Details is built (the swap's ~0.45 s): what the page
/// needs, from memory / disk (the background queue put it there —
/// `TitlePreloader`) — handed to the page as it's created, so it opens
/// complete in ONE build. Whatever isn't ready by then loads as before.
@MainActor
final class DetailPreparer {
    static let shared = DetailPreparer()

    final class Prepared {
        let id: String
        let tmdb: TMDBSettings
        var meta: MetaItem?
        var extras: [Int: [Int: TMDBService.EpisodeExtra]] = [:]
        var ratings: MDBListRatings?
        var detail: TMDBService.Detail?
        var collectionParts: [MetaItem]?
        /// The title block's season count / status chip and tagline (Details
        /// loaded them after its first frame: they changed as it took over).
        var showInfo: TMDBService.ShowSize?
        var tagline: String?
        var textReady = false
        /// The first row's name under the billboard, as Details will show it
        /// (a show: Play's season; a movie: More Like This / the collection).
        var firstRowName: String?
        var rowNameReady = false
        /// Details, ratings, the collection: all asked.
        var dataDone = false
        /// The picture Details shows: the one chosen for this opening
        /// (`TitlePictures`; from the billboard, the billboard's), else —
        /// once it's in — the record's.
        var picture: String?
        /// Choosing TMDB's picture (done: `picture` set — TMDB's or, without
        /// one, the card's / the record's).
        var pictureChoice: Task<Void, Never>?
        var pictureChosen = false
        /// Not chosen and decoded by the time the transition needed it:
        /// Details opens on the page's background, the picture fades in.
        var pictureLate = false
        /// The logo Home showed (else the record's).
        var logo: String?
        init(id: String, tmdb: TMDBSettings) { self.id = id; self.tmdb = tmdb }
    }

    private var current: Prepared?
    private var startedAt: CFTimeInterval = 0

    func start(_ item: MetaItem, keepsPicture: Bool = false) {
        guard let context = TitlePreloader.shared.context, !item.id.hasPrefix("tmdb:") else { return }
        let prepared = Prepared(id: item.id, tmdb: context.tmdb)
        if keepsPicture || !TMDBService.hasAPIKey {
            prepared.picture = Self.homePicture(item)
            prepared.pictureChosen = true
        } else {
            let choice = TitlePictures.shared.forOpening(item)
            prepared.pictureChoice = Task { @MainActor in
                let url = await choice.value
                prepared.picture = url ?? Self.homePicture(item)
                    ?? prepared.meta.flatMap { $0.background ?? $0.poster }
                prepared.pictureChosen = true
            }
        }
        prepared.logo = item.logo
        current = prepared
        startedAt = CACurrentMediaTime()
        let tmdb = context.tmdb
        Task { @MainActor in
            await TitleRecords.shared.refresh(item, [.show, .facts])
            prepared.showInfo = TitleRecords.shared.size(item)
            prepared.tagline = TitleRecords.shared.tagline(item)
            prepared.textReady = true
        }
        Task { @MainActor in
            async let ratings = MDBListService.ratings(for: item, settings: context.mdb)
            async let detail: TMDBService.Detail? = TMDBService.hasAPIKey
                ? TMDBService.detail(imdbID: item.id, type: item.type) : nil
            let meta = await SeriesEpisodes.fullMeta(for: item, addonManager: context.addonManager)
            // (Before the record is marked ready: the window draws with them.)
            prepared.ratings = await ratings
            if meta.isSeries, tmdb.useEpisodes, TMDBService.hasAPIKey {
                let id = meta.id, type = meta.type
                prepared.extras = await withTaskGroup(of: (Int, [Int: TMDBService.EpisodeExtra]).self) { group in
                    for season in meta.seasons {
                        group.addTask { (season, await TMDBService.seasonEpisodes(imdbID: id, type: type, season: season)) }
                    }
                    var all: [Int: [Int: TMDBService.EpisodeExtra]] = [:]
                    for await (season, extras) in group where !extras.isEmpty { all[season] = extras }
                    return all
                }
            }
            if meta.isSeries {
                let order = SeriesEpisodes.inPlayOrder(meta)
                let target = SeriesEpisodes.playTarget(meta.id, in: order, progress: context.progress,
                                                       watched: context.watched)
                let seasons = meta.seasons.sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
                prepared.firstRowName = (target?.season ?? seasons.first).map { $0 == 0 ? "Specials" : "Season \($0)" }
                    ?? "Episodes"
                prepared.rowNameReady = true
            }
            // (The episode list last of the three: the page takes meta and
            // its extras together.)
            if prepared.picture == nil, prepared.pictureChosen { prepared.picture = meta.background ?? meta.poster }
            if prepared.logo == nil { prepared.logo = meta.logo }
            prepared.meta = meta
            prepared.detail = await detail
            if !meta.isSeries {
                if tmdb.useMoreLikeThis, prepared.detail?.moreLikeThis.isEmpty == false {
                    prepared.firstRowName = "More Like This"
                } else if tmdb.useCollections, let collection = prepared.detail?.collection {
                    prepared.firstRowName = collection.name
                }
                prepared.rowNameReady = true
            }
            if tmdb.useCollections, let collection = prepared.detail?.collection {
                prepared.collectionParts = await TMDBService.collectionItems(id: collection.id)
                    .filter { $0.id != meta.id }.deduplicatedByID()
            }
            prepared.dataDone = true
            DetailOpenProbe.note(String(format: "prepared (%.0f ms after start)", (CACurrentMediaTime() - self.startedAt) * 1000))
        }
    }

    /// How long the transition waits for TMDB's picture to be chosen and
    /// decoded (focus usually did it already).
    static let choiceWait: Double = 0.5

    /// Details' picture (its record's), once it's decoded at the size
    /// Details draws it — nil if that took longer than `within`.
    func picture(for item: MetaItem, within: Double) async -> String? {
        guard let prepared = current, prepared.id == item.id else { return nil }
        // TMDB's picture, chosen at focus (decoded then): a short wait at
        // most — not in by then, Details opens on the page's background and
        // the picture fades in when it's there.
        let short = CACurrentMediaTime() + Self.choiceWait
        while !prepared.pictureChosen, CACurrentMediaTime() < short {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard prepared.pictureChosen else {
            prepared.pictureLate = true
            DetailOpenProbe.note("picture late")
            return nil
        }
        let deadline = CACurrentMediaTime() + within
        while prepared.picture == nil, prepared.meta == nil, CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let url = prepared.picture else { return nil }
        let decoded = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await ImageCache.shared.preload(url, maxDimension: PictureSize.screen) }
            group.addTask {
                let left = deadline - CACurrentMediaTime()
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        DetailOpenProbe.note("picture \(decoded)")
        return decoded ? url : nil
    }

    /// Everything Details shows on arrival is in — its data, the text, the
    /// first row's name, the logo, picture, blurred picture and colours
    /// decoded — or `within` seconds have passed. Details is only shown then
    /// (`DetailTransition`): no placeholders, nothing arriving after.
    func ready(_ item: MetaItem, within: Double) async {
        guard let prepared = current, prepared.id == item.id else { return }
        let deadline = CACurrentMediaTime() + within
        func done() -> Bool {
            prepared.meta != nil && prepared.textReady && prepared.rowNameReady && prepared.dataDone
        }
        while !done(), CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let meta = prepared.meta else { return }
        let logo = prepared.logo ?? meta.logo
        let picture = prepared.pictureLate ? nil : prepared.picture
        let stills = peekStills(meta, extras: prepared.extras, fallback: picture)
        await withTaskGroup(of: Void.self) { group in
            if let logo { group.addTask { await ImageCache.shared.preload(logo, maxDimension: PictureSize.logo) } }
            // The episodes' peek: its first cards' stills (created just
            // before the rise, they loaded then — the name rose alone and
            // the cards popped in at its end).
            if !stills.isEmpty {
                group.addTask { @MainActor in
                    await FixedFocusImages.prefetch(stills, within: .seconds(max(0, deadline - CACurrentMediaTime())))
                }
            }
            if let picture {
                group.addTask { await ImageCache.shared.preload(picture, maxDimension: PictureSize.screen) }
                group.addTask { _ = await BlurredBackdrop.image(for: picture) }
                group.addTask { _ = await FixedFocusTint.colors(for: picture) }
            }
            group.addTask {
                let left = deadline - CACurrentMediaTime()
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            }
            // All the pictures, or the deadline: whichever first.
            var pending = (logo != nil ? 1 : 0) + (picture != nil ? 3 : 0) + (stills.isEmpty ? 0 : 1)
            while pending > 0, await group.next() != nil {
                pending -= 1
                if CACurrentMediaTime() >= deadline { break }
            }
            group.cancelAll()
        }
        DetailOpenProbe.note("ready")
    }

    /// The stills of the episodes' peek — Play's episode and the next few
    /// in play order (the row opens aimed there) — at the cards' size, as
    /// `buildEpisodeRowItems` picks them. None while spoilers are hidden
    /// (those cards draw a blurred picture).
    private func peekStills(_ meta: MetaItem, extras: [Int: [Int: TMDBService.EpisodeExtra]],
                            fallback: String?) -> [(url: String?, maxDimension: CGFloat)] {
        guard meta.isSeries, !UserDefaults.standard.bool(forKey: DetailHideSpoilers.key),
              let context = TitlePreloader.shared.context else { return [] }
        let order = SeriesEpisodes.inPlayOrder(meta)
        let target = SeriesEpisodes.playTarget(meta.id, in: order, progress: context.progress,
                                               watched: context.watched)
        let start = target.flatMap { t in order.firstIndex { $0.id == t.id } } ?? 0
        let size = PictureSize.landscape
        return order.dropFirst(max(0, start - 1)).prefix(7).map { episode in
            let extra = episode.episode.flatMap { extras[episode.season ?? 0]?[$0] }
            return (TMDBService.originalSize(extra?.still) ?? episode.thumbnail ?? fallback, size)
        }
    }

    /// The picture Home shows for `item` (the billboard's: TMDB's, chosen
    /// with the picks; a card's: its add-on's — TMDB's original file).
    static func homePicture(_ item: MetaItem) -> String? {
        TMDBService.originalSize(item.background) ?? item.background
    }

    /// What's ready for `id`, left for Details (the window draws with it).
    func peek(_ id: String) -> Prepared? { current?.id == id ? current : nil }

    /// What's ready for `id` now (once).
    func take(_ id: String) -> Prepared? {
        guard let current, current.id == id else { return nil }
        self.current = nil
        DetailOpenProbe.note("take: meta \(current.meta != nil) · extras \(current.extras.count) · details \(current.detail != nil) · ratings \(current.ratings != nil) · id \(id) · meta id \(current.meta?.id ?? "-") · seasons \(current.meta?.seasons ?? []) · more \(current.detail?.moreLikeThis.prefix(2).map(\.name) ?? [])")
        return current
    }
}

/// Behind a page opened from Details (a person, a studio, a genre, a tag):
/// whatever the Background setting, that title's page as it is below
/// the billboard — its picture blurred and dimmed (`DetailView.rowsBackdrop`). Without a picture: the
/// app's background.
struct DetailsBackdropBackground: View {
    let url: String?
    /// Details made it: there from the first frame.
    @State private var blurred: UIImage?

    init(url: String?) {
        self.url = url
        _blurred = State(initialValue: BlurredBackdrop.cached(for: url))
    }

    var body: some View {
        ZStack {
            ATVBackground()
            if url != nil {
                ZStack {
                    Color.black
                    if let blurred {
                        Image(uiImage: blurred)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 1920, height: 1080)
                            .clipped()
                    }
                    Color.black.opacity(StageArt.dimBelow(for: url))
                }
                .frame(width: 1920, height: 1080)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: url ?? "") {
            guard blurred == nil else { return }
            let image = await BlurredBackdrop.image(for: url)
            withAnimation(Motion.fade) { blurred = image }
        }
    }
}

/// Over Details' logo, where Home's billboard says why it picked a title:
/// Up opens the trailer full screen — "Watch full screen" while it plays
/// on the picture, else "Watch the trailer". Only once one is known to
/// play; the chevron bobs now and then (`SectionHint`).
struct DetailTrailerHint: View {
    @ObservedObject var model: DetailViewModel
    @ObservedObject var trailer: StageTrailer
    /// Opened in place from Home's billboard: in with the peek.
    private var opening = BillboardOpening.shared

    var body: some View {
        ZStack(alignment: .leading) {
            if model.trailerReady || trailer.shown, !opening.detailsArriving {
                SectionHint(title: trailer.shown ? "Watch full screen" : "Watch the trailer", up: true)
                    .transition(FixedFocusBillboardText.leadSwap)
            }
        }
        // Its own (the change comes through another host: the transaction's
        // animation didn't reach it — it popped in).
        .animation(Motion.move, value: opening.detailsArriving)
    }
}
