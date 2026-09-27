import SwiftUI
import AVKit

let detailButtonSize: CGFloat = 78
let episodeSlideDuration: Double = 0.15      // row slide
let episodeLiftDelay: Duration = .milliseconds(110)  // lift starts just before slide ends
let episodeLiftAnimation: Animation = .easeOut(duration: 0.12)  // the grow itself

// MARK: - Detail pages
//
// The Detail page is three "pages", each a full screen: Overview (logo,
// text, buttons), Episodes (series only) and More (cast, collection, …).
// Moving focus into another page scrolls it to the top of the screen.

/// The page-to-page scroll: quick start, long gentle finish.
let detailPageScroll: Animation = .timingCurve(0.15, 0.85, 0.25, 1, duration: 0.65)

enum DetailPage: Hashable { case overview, episodes, more }

/// The season selector's name widths, by season.
private struct SeasonWidthKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var meta: MetaItem {
        didSet {
            episodeCache.removeAll()
            allEpisodesCache = nil
        }
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
    @Published var trailers: [TMDBService.Trailer] = []
    @Published var comments: [TraktService.Comment] = []
    @Published var mdbRatings: MDBListRatings?
    @Published var crew: [TMDBService.CastMember] = []
    @Published var director: String?
    @Published var country: String?
    @Published var language: String?
    /// The title block's TMDB extras (creator line, status, runtime, …).
    @Published var facts: TMDBService.TitleFacts?
    @Published var releaseDate: String?
    @Published var contentRating: String?
    @Published var parentalGuide: [ParentalGuideEntry] = []
    /// Per-season episode extras (rating / air date), keyed season → episode.
    @Published var episodeExtras: [Int: [Int: TMDBService.EpisodeExtra]] = [:]
    @Published var episodeCasts: [String: [TMDBService.CastMember]] = [:]
    private var loadingEpisodeCast = Set<String>()

    init(item: MetaItem) {
        meta = item
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

    func load(addonManager: AddonManager, mdbSettings: MDBListSettings = .default, tmdb: TMDBSettings = .default, parentalGuideEnabled: Bool = false) async {
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
        if meta.id.hasPrefix("tmdb:"), let n = Int(meta.id.dropFirst("tmdb:".count)),
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !meta.isSeries) {
            meta = MetaItem(
                id: tt, type: meta.type, name: meta.name,
                poster: meta.poster, background: meta.background, logo: meta.logo,
                description: meta.description, releaseInfo: meta.releaseInfo,
                imdbRating: meta.imdbRating, runtime: meta.runtime,
                genres: meta.genres, cast: meta.cast, videos: meta.videos
            )
        }
        // Kick off TMDB enrichment + Trakt comments in parallel with the meta fetch.
        // No key, no enrichment: TMDB now runs on the viewer's own key, and
        // without one every one of these requests is a guaranteed 401.
        let enrichTask = TMDBService.hasAPIKey
            ? Task { await TMDBService.detail(imdbID: meta.id, type: meta.type) }
            : nil
        let commentsTask = Task { await TraktService.comments(imdbID: meta.id, type: meta.type) }
        let ratingsTask = Task { await loadMDBRatings(settings: mdbSettings) }

        // Ask every meta add-on that could serve this id, not just the first.
        //
        // The first answer used to be the only answer, so a series from a
        // catalog-only add-on (Kaptain's mega collection and friends) whose id
        // no installed meta provider really serves came back with a name and
        // NO `videos` — a detail page with no season or episode list at all,
        // and nothing that tried anybody else. Keep the first usable meta as a
        // floor and keep going until one carries episodes.
        var best: MetaItem?
        // Capped: a viewer with a dozen meta add-ons installed should not pay a
        // dozen serial round trips on a title none of them can serve. Four is
        // past the id-prefix matches and a couple of long shots.
        for addon in addonManager.metaAddons(for: meta.type, id: meta.id).prefix(4) {
            guard let full = try? await StremioAPI.meta(addon: addon, type: meta.type, id: meta.id)
            else { continue }
            if best == nil { best = full }
            // A movie has nothing more to find; a series is only done when it
            // has an episode list.
            guard meta.isSeries else { break }
            if !(full.videos ?? []).isEmpty { best = full; break }
        }
        if let best { meta = best }
        // Still no episodes: TMDB knows the structure of essentially every
        // series, and an episode list from there is far better than a detail
        // page that can't be played.
        if meta.isSeries, (meta.videos ?? []).isEmpty, TMDBService.hasAPIKey {
            let episodes = await TMDBService.episodes(for: meta.id, type: meta.type)
            if !episodes.isEmpty {
                meta = MetaItem(
                    id: meta.id, type: meta.type, name: meta.name,
                    poster: meta.poster, background: meta.background, logo: meta.logo,
                    description: meta.description, releaseInfo: meta.releaseInfo,
                    imdbRating: meta.imdbRating, runtime: meta.runtime,
                    genres: meta.genres, cast: meta.cast, videos: episodes
                )
            }
        }
        if selectedSeason == nil {
            selectedSeason = meta.regularSeasons.first ?? meta.seasons.first
        }
        if let season = selectedSeason { await loadSeason(season) }
        // Episodes are ready now — stop blocking the episode section (gated on
        // `isLoading`) behind Trakt comments / MDBList ratings / parental guide
        // below. Those are unrelated to episodes and can each be slow
        // themselves; a meta addon that aggregates several sources per request
        // (e.g. AIOMetadata) was already the slow part of this load, and
        // chaining three more independent network calls after it responded
        // just made "episodes" wait even longer for no reason.
        isLoading = false

        // Unwinding on cancellation: the garnish tasks below were already
        // launched — kill them rather than let three network round trips run
        // to completion for a page the viewer left. (Each aborted visit used
        // to orphan all three.)
        if Task.isCancelled {
            enrichTask?.cancel()
            commentsTask.cancel()
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
            await self.apply(detail: await enrichTask?.value ?? nil, tmdb: tmdb)
            self.comments = await commentsTask.value
            // A failed load never replaces ratings handed over from the
            // billboard (the row would shrink to the fallback and back).
            let ratings = await ratingsTask.value
            if ratings != nil || self.mdbRatings == nil { self.mdbRatings = ratings }
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
        if tmdb.useTrailers { trailers = detail.trailers }
        if tmdb.useCollections {
            collection = detail.collection
            if let collection {
                collectionParts = await TMDBService.collectionItems(id: collection.id)
                    .filter { $0.id != meta.id }
                    .deduplicatedByID()
            }
        }
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

    func loadCast(for episode: MetaVideo) async {
        guard meta.isSeries, episodeCasts[episode.id] == nil, !loadingEpisodeCast.contains(episode.id) else { return }
        loadingEpisodeCast.insert(episode.id)
        defer { loadingEpisodeCast.remove(episode.id) }
        let cast = await TMDBService.episodeCast(imdbID: meta.id, type: meta.type, episode: episode)
        // A cancelled cell task (scrolled away / page dismissed) must not
        // publish — each insert re-renders the whole page.
        if !Task.isCancelled, !cast.isEmpty { episodeCasts[episode.id] = cast }
    }
}


struct DetailView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var layout: HomeCatalogSettingsStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @StateObject private var viewModel: DetailViewModel

    let onPlay: (MetaItem, MetaVideo?) -> Void
    /// Open the manual source list, bypassing Auto Link Selector (hold-Play).
    var onPlayManually: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    /// Resolve the auto-picked link and hand it to Infuse (hold-Play).
    var onPlayInInfuse: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    let onPlayFromBeginning: (MetaItem, MetaVideo?) -> Void
    var onSelectItem: (MetaItem) -> Void = { _ in }
    var onSelectPerson: (Int, String) -> Void = { _, _ in }
    var onSelectCompany: (Int, String) -> Void = { _, _ in }
    @State private var activeTrailer: TMDBService.Trailer?
    /// The action row's controls, for the enter-lands-on-Play redirect.
    private enum ActionControl: Hashable {
        case play, library, trailer
    }
    /// Entering the action row from ANY direction lands on the Play button:
    /// when focus arrives on any other control while the row didn't previously
    /// hold focus, it's immediately redirected to Play. (`.focusScope`, and
    /// `.defaultFocus` applied to the ROW, both BROKE directional entry into
    /// the row's focusSection on tvOS 26; this manual redirect doesn't. The
    /// `.defaultFocus` on the scroll view in `body` is a different thing —
    /// it only decides the page's OPENING focus, not directional moves.)
    @FocusState private var actionFocus: ActionControl?
    /// The button row as DRAWN: the one that is a pill (the focused one —
    /// or, focus elsewhere, the last focused), and whether it's focused
    /// (white). Both follow focus after `DetailActionButton.paintDelay`, so
    /// a one-frame visit (a vertical move lands on a circle before the
    /// row's redirect puts focus on Play) never paints.
    @State private var pillAction: ActionControl = .play
    @State private var litAction: ActionControl?
    /// The widest title (all the row's titles, measured) — every pill is
    /// this wide, so the row's edges never move.
    @State private var maxTitleWidth: CGFloat = 0
    /// The episode that currently holds focus, reported by `EpisodeCell`'s
    /// `onFocus` callback. Drives the "focused episode stays in the first
    /// column, the row slides" scroll in `episodesSection`.
    @State private var focusedEpisode: String?
    /// Programmatic focus INTO the episode row (Down from the buttons lands
    /// on an episode, not on the season chips).
    @FocusState private var episodeFocus: String?
    /// Which page holds focus — drives the page scroll, the backdrop
    /// darkening and the trailer (Overview only).
    @State private var page: DetailPage = .overview
    /// Opened from Home's billboard: this page plays its half of the swap
    /// in, and Back plays it out and returns (see `ModeSwap`).
    @State private var fromBillboard: Bool
    private let onReturnToBillboard: (() -> Void)?
    /// Opened from a catalog box: the title block fades in with the buttons
    /// (the box had none), and out with them on Back.
    @State private var fromBox: Bool
    /// From a box: the scrim arrives half-way (the growing box took it that
    /// far) and finishes with the page's parts; Back takes it half-way back.
    @State private var scrim: Double
    /// The billboard's season count ("3 Seasons") when opened from there.
    /// State, not a plain property: SwiftUI re-creates this view while the
    /// page is up, and only the FIRST creation still sees the handoff.
    @State private var billboardSeriesSize: String?
    /// The backdrop's depth, 0…1 (see `ModeSwap.depthHandover`): from the
    /// billboard it arrives part-way (Home began it) and finishes with the
    /// buttons; leaving, it goes part-way back and Home finishes it.
    @State private var depth: CGFloat
    /// This page's own parts (buttons, the hint) are in.
    @State private var swappedIn: Bool
    /// The More-page row that has focus; each one scrolls to the same spot.
    @State private var moreRow: MoreRow?
    /// The season row opens on the Play target's season, once.
    @State private var seasonAutoPicked = false

    // Episode row (Home-spotlight style): ONE focusable box at a fixed spot,
    // the row slides underneath. Continuous across the regular seasons;
    // the Specials chip switches the row to the specials.
    @State private var episodeIndex = 0
    /// The episode row moves like Home's rows: the cards' resistance nudge,
    /// a heavy step across a season seam, the pressed ‹ ›, the pressed
    /// seam card.
    @State private var episodeNudge: CGFloat = 0
    @State private var episodeWrapping = false
    @State private var episodePressedChevron = 0
    @State private var seasonSeamPressed = false
    /// The season selector above the box has focus.
    @FocusState private var seasonFocused: Bool
    /// The season names' widths (at full size), for the selector's layout.
    @State private var seasonWidths: [Int: CGFloat] = [:]
    /// Which way the season names last moved (for their slide).
    @State private var seasonStep = 1
    private enum RowSlot: Hashable { case box, left, right }
    @FocusState private var rowFocus: RowSlot?
    /// How Play was pressed while a series' episode list was still loading —
    /// replayed against the real episode the moment it resolves.
    private enum PendingPlay { case auto, manual, infuse }
    @State private var pendingSeriesPlay: PendingPlay?
    @State private var showRatingPicker = false
    /// The ⋯ button's choices (rate, watched, start over, play manually).
    /// Trailer playing silently in the backdrop after the idle delay.
    @State private var backdropPlayer: AVPlayer?
    @State private var showBackdropTrailer = false
    /// Loop observer for the backdrop trailer, removed on teardown — otherwise
    /// every Detail visit leaves a dead block registered with the notification
    /// center forever.
    /// Fires when the backdrop trailer reaches its end — see
    /// `restoreBackdropArtwork()`.
    @State private var backdropEndToken: NSObjectProtocol?
    /// Holds the teardown until the fade has finished. Cancellable, because a
    /// page leaving (or a new trailer arming) must win over a fade in flight.
    @State private var backdropFadeTask: Task<Void, Never>?
    /// Netflix-style: once the muted backdrop trailer has been playing and the
    /// user stays idle a beat longer, the page chrome fades away and the
    /// trailer takes the full screen (with sound). Any press/move restores.
    @State private var trailerFullscreen = false
    @State private var teaserFocused = false
    /// The synopsis teaser becomes focusable only once Play has held focus
    /// (or a moment has passed). It is the topmost focusable on the page, so
    /// whenever the engine re-resolved — the page's data landing a beat after
    /// the first frame — it went there, and the correction back to Play was
    /// the visible "starts on the plot, then jumps" hop. Unfocusable, it can't
    /// be the engine's pick; Up from Play reaches it as soon as it is armed.
    @State private var teaserArmed = false
    /// Bumped on any tracked focus change; re-arms (or cancels) the idle timer.
    @State private var interactionCount = 0
    /// Set when the user backs OUT of full-screen: the idle timer stays
    /// disarmed until they actually move again, so exiting doesn't bounce
    /// straight back into full-screen after the next 2 idle seconds.
    @State private var fullscreenCooldown = false
    /// When full-screen was last exited; focus changes inside a short window
    /// after it are the programmatic restore, not the user moving.
    @State private var fullscreenExitedAt = Date.distantPast
    /// True only while the muted backdrop trailer is actually rendering
    /// frames. `showBackdropTrailer` flips as soon as the player is created,
    /// long before the first frame — full-screen used to fade the chrome out
    /// over the static backdrop, then eat the next press to come back.
    @State private var backdropTrailerPlaying = false
    /// Up / Back in trailer mode: the page is back, the trailer runs on
    /// muted (see `TrailerMode`).
    @State private var trailerRevealed = false
    /// The trailer's sound took the audio session (given back on teardown).
    @State private var trailerAudioActive = false
    @State private var backdropStatusObserver: NSKeyValueObservation?
    /// Watches the ITEM, not the player — see `startBackdropTrailerIfEnabled`.
    @State private var backdropItemObserver: NSKeyValueObservation?
    @FocusState private var fullscreenTrailerFocus: Bool

    init(
        item: MetaItem,
        onPlay: @escaping (MetaItem, MetaVideo?) -> Void,
        onPlayManually: @escaping (MetaItem, MetaVideo?) -> Void = { _, _ in },
        onPlayInInfuse: @escaping (MetaItem, MetaVideo?) -> Void = { _, _ in },
        onPlayFromBeginning: @escaping (MetaItem, MetaVideo?) -> Void = { _, _ in },
        onSelectItem: @escaping (MetaItem) -> Void = { _ in },
        onSelectPerson: @escaping (Int, String) -> Void = { _, _ in },
        onSelectCompany: @escaping (Int, String) -> Void = { _, _ in },
        onReturnToBillboard: (() -> Void)? = nil
    ) {
        let fromBillboard = MainActor.assumeIsolated { ModeSwap.shared.billboardItemID == item.id }
        let model = DetailViewModel(item: item)
        if fromBillboard {
            // Start with exactly what the billboard showed — nothing in the
            // title block may change as the page takes over.
            MainActor.assumeIsolated {
                model.mdbRatings = ModeSwap.shared.billboardRatings
                model.facts = ModeSwap.shared.billboardFacts
            }
        }
        _viewModel = StateObject(wrappedValue: model)
        _fromBillboard = State(initialValue: fromBillboard)
        let fromBox = fromBillboard && MainActor.assumeIsolated { ModeSwap.shared.arrivedFromBox }
        _fromBox = State(initialValue: fromBox)
        _scrim = State(initialValue: fromBox ? ModeSwap.boxScrimHandover : 1)
        _depth = State(initialValue: fromBox ? ModeSwap.boxDepthHandover
                       : fromBillboard ? ModeSwap.depthHandover : 1)
        _billboardSeriesSize = State(initialValue: fromBillboard
            ? MainActor.assumeIsolated { ModeSwap.shared.billboardSeriesSize } : nil)
        _swappedIn = State(initialValue: !fromBillboard)

        self.onReturnToBillboard = onReturnToBillboard
        self.onPlay = onPlay
        self.onPlayManually = onPlayManually
        self.onPlayInInfuse = onPlayInInfuse
        self.onPlayFromBeginning = onPlayFromBeginning
        self.onSelectItem = onSelectItem
        self.onSelectPerson = onSelectPerson
        self.onSelectCompany = onSelectCompany
    }

    /// Whether SOME auto-selection will act on Play — the per-profile Auto
    /// Link Selector or the global "Auto-play best source". Either one means
    /// Play skips the source list, so either one earns the hold-for-manual
    /// menu; gating on the selector alone left global-auto-play users with no
    /// way to reach the list at all.
    private var autoLinkOn: Bool {
        profiles.activeAutoLink.enabled || playerSettings.settings.autoPlaySourceEnabled
    }

    var body: some View {
        ZStack {
            ATVBackground()
            backdrop
            // Full screen, like Home's spotlight: the pages place everything
            // themselves with the SAME margins and label heights as Home.
            GeometryReader { geo in
                ScrollViewReader { pageProxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            overviewPage(size: geo.size)
                                .id(DetailPage.overview)
                            if viewModel.meta.isSeries {
                                episodesPage(size: geo.size)
                                    .id(DetailPage.episodes)
                            }
                            if morePageTitle != nil {
                                morePage(height: geo.size.height)
                                    .id(DetailPage.more)
                            }
                        }
                    }
                    .scrollClipDisabled()
                    // Only OUR scrolls move the page (pages, More rows). Left
                    // to it, the focus engine scrolls too — just enough to
                    // show the focused view — and the two fought.
                    .scrollDisabled(true)
                    // Between the More page's rows: the same fast-then-slow
                    // scroll, bringing each row to the spot the first one has.
                    .onChange(of: moreRow) { _, row in
                        guard let row else { return }
                        withAnimation(detailPageScroll) { pageProxy.scrollTo(row, anchor: .top) }
                        // As for pages: win over the focus engine's own scroll.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            guard moreRow == row else { return }
                            withAnimation(detailPageScroll) { pageProxy.scrollTo(row, anchor: .top) }
                        }
                    }
                    // Focus entered another page: bring that page's top to
                    // the top of the screen.
                    .onChange(of: page) { _, newPage in
                        if newPage != .more { moreRow = nil }
                        withAnimation(detailPageScroll) {
                            pageProxy.scrollTo(newPage, anchor: .top)
                        }
                        // The focus engine scrolls too — just enough to show
                        // the newly focused view — and that can stop our
                        // scroll short (coming back up from deep in More).
                        // Scroll again once it's done, so the page wins.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            guard page == newPage else { return }
                            withAnimation(detailPageScroll) {
                                pageProxy.scrollTo(newPage, anchor: .top)
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea()
            // Play owns the page from the first frame. Without this the focus
            // engine picks the topmost focusable — the synopsis teaser — and
            // the action row's entry redirect then hops focus down to Play in
            // a later frame, which reads as the page snatching focus away from
            // whatever you were looking at.
            .defaultFocus($actionFocus, .play)
            .opacity(trailerFullscreen ? 0 : 1)
            // Hidden is NOT unfocusable: without this, focus could stay on the
            // invisible synopsis during full-screen — whose move-handler then
            // swallowed every press, locking full-screen mode in.
            .disabled(trailerFullscreen)

            // Full-screen trailer mode: an invisible focusable overlay holds
            // focus; ANY input — move, Select, Menu, ⏯ — restores the page.
            // NOT a Button: one with a fully transparent label never becomes
            // focusable, so nothing held focus and full-screen locked in.
            if trailerFullscreen {
                Color.black.opacity(0.001)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .focusable()
                    .focused($fullscreenTrailerFocus)
                    .onMoveCommand { _ in exitTrailerFullscreen() }
                    .onExitCommand { exitTrailerFullscreen() }
                    .onPlayPauseCommand { exitTrailerFullscreen() }
                    .onTapGesture { exitTrailerFullscreen() }
            }
        }
        // Arm the idle → full-screen countdown only while the viewer is resting
        // on the SYNOPSIS — never while focus is on the action row.
        //
        // Resting on Play is not idling: Play is this page's DEFAULT focus, so
        // the countdown fired on every visit and dissolved the page a few
        // seconds after it opened (device trailer delay 3s + 6s idle). The
        // chrome goes to `.opacity(0)` and `.disabled`, which DELETES the Play
        // button mid-visit: a hold-Select that overlaps the takeover is
        // cancelled, and one attempted after it only restores the chrome. That
        // is the second, independent half of "the hold menu on Play doesn't
        // work" — measured on the sim: without this gate the page reached
        // `fs=1` 17s after opening and focus was stranded off the row; with it,
        // Play held focus for 14m45s across 205 samples and it never fired.
        // Full screen is still reachable on demand from the trailer button.
        .task(id: "\(backdropTrailerPlaying)#\(interactionCount)#\(trailerFullscreen)") {
            guard backdropTrailerPlaying, !trailerFullscreen, !fullscreenCooldown,
                  activeTrailer == nil, !showRatingPicker,
                  teaserFocused, actionFocus == nil else { return }
            // A real rest, not a reading pause: the first press after the
            // chrome fades only brings it back, so this must never fire while
            // someone is still deciding.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, backdropTrailerPlaying, !trailerFullscreen,
                  !fullscreenCooldown, activeTrailer == nil, !showRatingPicker,
                  teaserFocused, actionFocus == nil,
                  !PiPHandoff.shared.isActive else { return }
            // Un-muting needs a live audio session — the muted backdrop
            // deliberately runs without one (a raw AVPlayer can stall on tvOS
            // otherwise), so without this the full-screen trailer was SILENT.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            backdropPlayer?.isMuted = false
            // A bare AVPlayerLayer doesn't suppress the tvOS screensaver the
            // way AVPlayerViewController does — without this the Aerial saver
            // rolled in over a full-screen trailer.
            UIApplication.shared.isIdleTimerDisabled = true
            withAnimation(.easeInOut(duration: 0.6)) { trailerFullscreen = true }
            // Deferred: set in the same transaction as the button's insertion
            // it can be ignored.
            try? await Task.sleep(for: .milliseconds(120))
            fullscreenTrailerFocus = true
        }
        .task {
            // Dev: -focusLog prints the focused item every 2s (sim key
            // delivery is flaky; this is the only reliable focus truth).
            if ProcessInfo.processInfo.arguments.contains("-focusLog") {
                while !Task.isCancelled {
                    let env = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
                    let item = env.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
                    NSLog("[OrivioFocus] focused=%@ fs=%d captureFocus=%d teaser=%d action=%@",
                          item.map { String(describing: $0).prefix(200) }.map(String.init) ?? "NONE",
                          trailerFullscreen ? 1 : 0,
                          fullscreenTrailerFocus ? 1 : 0,
                          teaserFocused ? 1 : 0,
                          actionFocus.map { String(describing: $0) } ?? "nil")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        // Trailer only on the Overview page: leaving it stops the trailer
        // at once (fully torn down, no decoder left running).
        .onChange(of: page) { _, newPage in
            if newPage != .overview { teardownBackdropTrailer() }
        }
        // Play pressed before the episode list arrived: run it now, against
        // the episode the loaded data actually points at.
        .onChange(of: seriesPlayTarget?.id) { _, _ in
            // The episode row opens on the season Play would start.
            // The episode row opens ON the episode Play would start.
            if !seasonAutoPicked, let target = seriesPlayTarget {
                seasonAutoPicked = true
                if let index = rowEpisodes.firstIndex(where: { $0.id == target.id }) {
                    episodeIndex = index
                }
                if let season = target.season { viewModel.selectedSeason = season }
            }
            guard let pending = pendingSeriesPlay, let target = seriesPlayTarget else { return }
            pendingSeriesPlay = nil
            switch pending {
            case .auto: onPlay(viewModel.meta, target)
            case .manual: onPlayManually(viewModel.meta, target)
            case .infuse: onPlayInInfuse(viewModel.meta, target)
            }
        }
        // `.defaultFocus($actionFocus, .play)` opens the page on Play, but it
        // LOSES A RACE on a cold start: the page's data lands a beat after the
        // first frame, the focus engine re-resolves, and the topmost focusable
        // — the synopsis teaser — takes focus instead. A show hides this (its
        // Play title changes to "Play S1:E1" when episodes arrive, which
        // re-settles the row); a movie's title never changes, so the page just
        // sits there with the synopsis lit. Reproduced against a freshly
        // installed app in `FocusTour.testDetailPlayHold`.
        //
        // So: for a short window after the page opens, move focus back to Play
        // whenever it is resting on the teaser. ONE writer, deferred, and it
        // stops the moment the action row holds focus — the rules the rest of
        // this page's focus code follows. It never touches a move to anywhere
        // else, so pressing Down into the cast row still works immediately.
        .task {
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(150))
                if actionFocus != nil || trailerFullscreen { return }
                guard teaserFocused else { continue }
                actionFocus = .play
            }
        }
        // Arm the teaser even if Play somehow never took focus, so the
        // synopsis is always reachable.
        .task {
            try? await Task.sleep(for: .seconds(2))
            teaserArmed = true
        }
        .task { await viewModel.load(addonManager: addonManager, mdbSettings: mdblist.settings, tmdb: tmdbSettings.settings, parentalGuideEnabled: playerSettings.settings.parentalGuideEnabled) }
        // Auto-play the trailer in the backdrop after the configured idle
        // delay. Re-runs once trailers finish loading. Resolves silently — no
        // loading UI — and only swaps in when the video is actually ready.
        .task(id: autoTrailerKey) {
            await startBackdropTrailerIfEnabled()
        }
        .onDisappear { teardownBackdropTrailer() }
        .onAppear {
            guard fromBillboard else { return }
            // Consumed: a title opened from here again is a normal push.
            ModeSwap.shared.billboardItemID = nil
            ModeSwap.shared.arrivedFromBox = false
            withAnimation(ModeSwap.in) {
                swappedIn = true
                depth = 1
                scrim = 1
            }
        }
        // Back, when opened from the billboard: from a lower page first up
        // to the overview; from the overview, this page's half of the swap
        // out, then Home plays the rest.
        // (In trailer mode Back first only brings the page back.)
        .onExitCommand(perform: trailerMode ? { revealTrailerPage() }
                       : fromBillboard && onReturnToBillboard != nil ? { backToBillboard() } : nil)
        // Trailer mode starts only while Play HOLDS focus: moving off it
        // (right to the other buttons, down to Episodes) stops the trailer;
        // back on Play the countdown starts over.
        .onChange(of: actionFocus) { _, new in
            if new != .play, backdropPlayer != nil { teardownBackdropTrailer() }
        }
        .onChange(of: trailerMode) { _, on in
            // A bare AVPlayerLayer doesn't hold off the screensaver.
            UIApplication.shared.isIdleTimerDisabled = on
        }
        // The player just handed its picture to the PiP window and dismissed
        // onto this page: a trailer already rolling underneath must go, for
        // the same reasons the auto-start above declines to begin one.
        .onReceive(NotificationCenter.default.publisher(for: PiPHandoff.didBeginNotification)) { _ in
            teardownBackdropTrailer()
        }
        // Opening the full-screen trailer or navigating to play: stop the
        // muted backdrop so two players don't fight over audio.
        .onChange(of: activeTrailer?.id) { _, newValue in
            if newValue != nil { backdropPlayer?.pause() }
        }
        .fullScreenCover(item: $activeTrailer) { trailer in
            // The alternates come along so a first pick that this connection
            // can't reach falls through to the next one instead of landing on
            // "Trailer unavailable".
            TrailerPlayerView(trailer: trailer,
                              alternates: viewModel.trailers.map(\.youtubeKey))
                .environmentObject(theme)
        }
        .fullScreenCover(isPresented: $showRatingPicker) {
            RatingPickerOverlay(
                title: viewModel.meta.name,
                current: ratings.rating(for: viewModel.meta.id)
            ) { newRating in
                ratings.setRating(newRating, for: viewModel.meta.id, type: viewModel.meta.type)
                showRatingPicker = false
                ToastCenter.shared.show("Rating Saved", icon: "star.fill")
            } onCancel: { showRatingPicker = false }
            .environmentObject(theme)
        }
    }

    private var backdrop: some View {
        GeometryReader { geo in
            ZStack {
                // Decorative backdrop — kept out of hit testing so it cannot
                // swallow the action row's context-menu hit test (the same bug
                // the home Featured bar caused for Continue Watching).
                RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster,
                            maxPixels: PerformanceProfile.backdropPixelCap)
                    .allowsHitTesting(false)
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Depth: the page leans in a little (see `ModeSwap.depth…`).
                    .scaleEffect(ModeSwap.depthScale(depth))
                // MOUNTED ALWAYS, revealed by opacity — never inserted into
                // the tree while the page is on screen. Inserting a
                // UIViewRepresentable makes the focus engine re-resolve (the
                // reason this view is `isUserInteractionEnabled = false` in
                // the first place), and the insertion lands ~3s after the page
                // opens: exactly when a viewer is reaching for hold-Select on
                // Play, whose long-press the re-resolve then cancels — the
                // "hold panel doesn't work any more" report. It used to be
                // hidden by how OFTEN extraction failed or ran long; caching
                // resolved URLs made it punctual and the collision routine.
                BackdropVideoView(player: backdropPlayer)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                    .opacity(showBackdropTrailer ? 1 : 0)
                    .scaleEffect(ModeSwap.depthScale(depth))
                // The shared scrim (same as Home's).
                StageScrim()
                    .opacity(trailerFullscreen ? 0 : trailerMode ? TrailerMode.scrimOpacity : scrim)
                    .animation(TrailerMode.fade, value: trailerMode)
                // Episodes / More: the same backdrop, darkened so cards and
                // text stay readable. It never scrolls.
                // One darkness for the whole page — overview, Episodes and
                // More alike (it no longer changes as you scroll): the depth
                // step, which comes in with the swap from the billboard. A
                // trailer having the screen lifts it.
                Color.black
                    .opacity(trailerMode ? 0 : ModeSwap.depthDim(depth))
                    .animation(.easeInOut(duration: 0.45), value: page)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    /// Changes when the delay setting or the first trailer changes, so the
    /// timed `.task` restarts appropriately.
    private var autoTrailerKey: String {
        "\(viewModel.trailers.first?.youtubeKey ?? "")#\(page == .overview)#\(actionFocus == .play)"
    }

    private func startBackdropTrailerIfEnabled() async {
        // Off for now (see `TrailerMode.enabled`).
        guard TrailerMode.enabled else { return }
        let delay = TrailerMode.delay
        // Reduce Motion keeps the still backdrop. An auto-starting, looping
        // trailer is unrequested motion by definition, and it escalates itself
        // to full screen a few seconds later — a large positional transition
        // the viewer never asked for and the setting's copy never mentions.
        guard !perf.reduceMotion else { return }
        // Overview page only; returning to it starts the trailer again.
        guard page == .overview, actionFocus == .play else { return }
        guard !viewModel.trailers.isEmpty else { return }
        // EVERY trailer the title has, best first — not just the top one. A
        // geo-restricted first pick (routine when the connection leaves the
        // house through a VPN exit in another country) used to be the end of
        // it; `backdropItem` now falls through to the next candidate.
        let candidates = viewModel.trailers.map(\.youtubeKey)
        // Resolve WHILE the idle delay runs, not after it — extraction (and
        // the remote fallback especially) can take several seconds, and
        // serializing it behind the delay made the trailer feel like forever.
        async let resolved = TrailerResolver.backdropItem(candidates: candidates)
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, actionFocus == .play else { return }
        // The title is playing in the Picture in Picture window (the player
        // dismissed onto this page): a second decoder and a full-screen
        // trailer that grabs and then drops the audio session would stall it.
        guard !PiPHandoff.shared.isActive else { return }
        guard let resolvedTrailer = await resolved else {
            NSLog("[OrivioTrailer] backdrop resolve failed for %@", candidates.joined(separator: ","))
            return
        }
        let item = resolvedTrailer.item
        guard !Task.isCancelled else { return }
        // This task re-runs whenever `autoTrailerKey` changes (the delay setting
        // or the trailer list). Tear the previous player down first, or the old
        // AVPlayer kept decoding/playing with its reference simply dropped —
        // two players fighting, and a leaked decoder. Full teardown also clears
        // its observers, item, audio session and fullscreen state.
        teardownBackdropTrailer()
        let player = AVPlayer(playerItem: item)
        // With sound (trailer mode) — which needs a live audio session, or a
        // raw AVPlayer on tvOS stays silent (or stalls).
        setTrailerSound(true, on: player)
        // Play ONCE and give the backdrop art back, rather than restarting
        // forever. `.none` rather than `.pause` so the player holds its last
        // frame at the end instead of resetting — that held frame is what
        // dissolves back into the artwork.
        player.actionAtItemEnd = .none
        // The task can re-run within one visit (autoTrailerKey change) —
        // release the previous observer before installing a new one.
        if let token = backdropEndToken { NotificationCenter.default.removeObserver(token) }
        backdropEndToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { _ in
            Task { @MainActor in restoreBackdropArtwork() }
        }
        backdropPlayer = player
        // A URL minted for a network path the box has since left (a VPN going
        // up or down mid-session) answers 403 rather than video, and the item
        // fails instead of ever playing. Forget it, so the next visit to this
        // title extracts again rather than replaying the same dead link for
        // the rest of the cache window.
        backdropItemObserver?.invalidate()
        // Capture the KEY, not the resolved pair — the observation outlives
        // this scope and shouldn't be the reason the item stays alive.
        let resolvedKey = resolvedTrailer.youtubeKey
        backdropItemObserver = item.observe(\.status, options: [.new]) { observed, _ in
            guard observed.status == .failed else { return }
            NSLog("[OrivioTrailer] backdrop %@ failed to load: %@", resolvedKey,
                  String(describing: observed.error))
            TrailerResolver.invalidate(youtubeKey: resolvedKey)
        }
        backdropStatusObserver?.invalidate()
        backdropStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in backdropTrailerPlaying = playing }
        }
        player.play()
        withAnimation(.easeInOut(duration: 0.6)) { showBackdropTrailer = true }
    }

    /// How long the backdrop trailer takes to dissolve back into the still
    /// art. Matches the Home hero's, so the two read as one behaviour.
    private static let backdropFadeSeconds: TimeInterval = 0.7

    /// The backdrop trailer finished. Dissolve it back into the still artwork,
    /// and only then take the player down.
    ///
    /// The order matters: `teardownBackdropTrailer` clears the layer's player,
    /// which empties it to black at once — doing that first and animating
    /// afterwards would fade out a black rectangle over the artwork instead of
    /// the trailer's last frame.
    ///
    /// A trailer that ends while the viewer has escalated it to FULL SCREEN is
    /// put back on the page first, through the same `exitTrailerFullscreen`
    /// that a Menu press uses — so the audio session, the idle timer, the
    /// cooldown and the focus hand-back to Play all happen exactly as they
    /// already do, rather than being re-implemented here. The dissolve follows
    /// once the page is back.
    @MainActor
    private func restoreBackdropArtwork() {
        guard backdropPlayer != nil else { return }
        guard showBackdropTrailer else { teardownBackdropTrailer(); return }
        let wasFullscreen = trailerFullscreen
        if wasFullscreen { exitTrailerFullscreen() }
        backdropFadeTask?.cancel()
        backdropFadeTask = Task { @MainActor in
            if wasFullscreen {
                // Let the page settle back before dissolving, so the two
                // animations read as one move rather than fighting.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, backdropPlayer != nil else { return }
            }
            withAnimation(.easeInOut(duration: Self.backdropFadeSeconds)) {
                showBackdropTrailer = false
            }
            try? await Task.sleep(for: .seconds(Self.backdropFadeSeconds))
            guard !Task.isCancelled else { return }
            teardownBackdropTrailer()
        }
    }

    /// Restore the detail page from full-screen trailer mode and put focus
    /// back on Play.
    private func exitTrailerFullscreen() {
        fullscreenCooldown = true
        fullscreenExitedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = false
        backdropPlayer?.isMuted = true
        // Give interrupted audio (another app's music) its shouldResume back —
        // full-screen mode activated the session to un-mute. Never while a
        // PiP session owns the session: deactivating it stops that audio.
        if !PiPHandoff.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        withAnimation(.easeInOut(duration: 0.35)) { trailerFullscreen = false }
        // AFTER the capture button leaves the tree and the focus engine's own
        // re-resolve has settled — set too early it gets overridden by the
        // geometrically nearest item (the synopsis). One request is not always
        // honored either (the engine can re-resolve onto the synopsis a beat
        // later), so keep asking for a few ticks until Play actually holds it.
        Task { @MainActor in
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !trailerFullscreen else { return }
                if actionFocus == .play && !teaserFocused { return }
                if actionFocus == .play {
                    // Stale binding (focus moved on without SwiftUI noticing):
                    // clear it on one tick so the next set is a real request.
                    actionFocus = nil
                    try? await Task.sleep(for: .milliseconds(30))
                }
                actionFocus = .play
            }
        }
    }

    /// The trailer has the screen: playing, and not brought back by Up /
    /// Back (see `TrailerMode`). Only then does anything vanish.
    private var trailerMode: Bool { backdropTrailerPlaying && !trailerRevealed && page == .overview }

    /// Up / Back in trailer mode: the page comes back, the trailer runs on
    /// muted.
    private func revealTrailerPage() {
        withAnimation(TrailerMode.fade) { trailerRevealed = true }
        if let backdropPlayer { setTrailerSound(false, on: backdropPlayer) }
    }

    private func setTrailerSound(_ sound: Bool, on player: AVPlayer) {
        if sound, !PiPHandoff.shared.isActive {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            trailerAudioActive = true
            player.isMuted = false
        } else {
            player.isMuted = true
        }
    }

    private func teardownBackdropTrailer() {
        // A fade still in flight is answered by whatever called this — the page
        // leaving, a new trailer arming, PiP taking over — so drop it rather
        // than letting it tear down a preview that has already been replaced.
        backdropFadeTask?.cancel()
        backdropFadeTask = nil
        if trailerFullscreen {
            UIApplication.shared.isIdleTimerDisabled = false
            if !PiPHandoff.shared.isActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        trailerFullscreen = false
        trailerRevealed = false
        if trailerAudioActive {
            trailerAudioActive = false
            if !PiPHandoff.shared.isActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        UIApplication.shared.isIdleTimerDisabled = false
        backdropStatusObserver?.invalidate()
        backdropStatusObserver = nil
        backdropItemObserver?.invalidate()
        backdropItemObserver = nil
        backdropTrailerPlaying = false
        // Clear the item too, not just pause — otherwise the muted backdrop
        // player stays the system "Now Playing" item and the tvOS transport
        // overlay can pop up over Home when Play/Pause is pressed.
        backdropPlayer?.pause()
        backdropPlayer?.replaceCurrentItem(with: nil)
        backdropPlayer = nil
        if let token = backdropEndToken {
            NotificationCenter.default.removeObserver(token)
            backdropEndToken = nil
        }
        showBackdropTrailer = false
    }

    // MARK: - Pages

    /// A page's hint, placed at a fixed height and shown ONLY while its own
    /// page is the current one — otherwise the next page's "▴ …" peeked in
    /// at the edge of this one (and this one's "▾ …" at the edge of that).
    private func hint(_ title: String?, up: Bool, on owner: DetailPage, y: CGFloat,
                      swapOut: Bool = false) -> some View {
        Group {
            if let title {
                // The shared signpost (same as Home's billboard); steps
                // aside on the overview while the trailer plays.
                SectionHint.place(
                    SectionHint(title: title, up: up,
                                hidden: false)
                        .offset(y: swapOut ? -ModeSwap.lift : 0)
                        .opacity(swapOut ? 0 : 1)
                        .animation(swapOut ? ModeSwap.fadeOut : ModeSwap.fadeIn, value: swapOut))
            }
        }
        .padding(.top, y)
        .opacity(page == owner ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: page)
    }

    /// Overview: the title block (logo, meta, description) exactly where
    /// Home's billboard shows it — see `TitleBlock` — and below it the
    /// buttons and the rest, in the space kept free for them.
    private func overviewPage(size: CGSize) -> some View {
        let height = size.height
        // The title block (`TitleBlock`): every part at a fixed spot, the
        // buttons in its button row. (The billboard is laid out the same.)
        return ZStack(alignment: .topLeading) {
            TitleBlockView(item: viewModel.meta, facts: viewModel.facts,
                           // From the billboard: its season count, so the
                           // meta line doesn't redraw as the page takes over.
                           seriesSize: billboardSeriesSize,
                           textHidden: trailerMode,
                           showsLogo: !trailerMode,
                           ratings: ratingsBadges)
                // From a box: fades in with the buttons (it wasn't there).
                .opacity(fromBox && !swappedIn ? 0 : 1)
                .padding(.leading, Spotlight.screenInset)
                .padding(.top, TitleBlock.topY(screenHeight: height))
            headerExtras
                // Each button grows out of a dot (`DotGrow`, per button).
                .frame(height: TitleBlock.buttonHeight)
                .padding(.top, TitleBlock.buttonsY(screenHeight: height))
        }
        .frame(height: height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            hint(viewModel.meta.isSeries ? "Episodes" : morePageTitle,
                 up: false, on: .overview, y: TitleBlock.hintY(screenHeight: height),
                 // Comes down into place from a little above (Home's went
                 // down off the screen) — see `ModeSwap`.
                 swapOut: !swappedIn)
        }
    }

    /// Episodes: the show's name, seasons + episode row. Exactly one screen,
    /// hints at Home's label heights.
    private func episodesPage(size: CGSize) -> some View {
        let height = size.height
        return VStack(alignment: .leading, spacing: 0) {
            // No big "Episodes" title — the "▴ Overview" hint above and the
            // season selector say where you are.
            episodesSection(width: size.width)
            Spacer(minLength: 0)
        }
        .padding(.top, Spotlight.topPadding + Spotlight.labelHeight + 24)
        .frame(height: height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            hint("Overview", up: true, on: .episodes, y: TitleBlock.topHintY)
        }
        .overlay(alignment: .topLeading) {
            hint(morePageTitle, up: false, on: .episodes, y: TitleBlock.hintY(screenHeight: height))
        }
    }

    /// More: every remaining section; each row, when focused, scrolls to
    /// the spot below the hint (`moreRowTop`).
    private func morePage(height: CGFloat) -> some View {
        // What you most likely want next first: something similar, the
        // rest of the collection, then who made it, then the footers.
        VStack(alignment: .leading, spacing: OrivioSpacing.xxl) {
            moreLikeThisSection
            collectionSection
            castSection
            companiesSection
            commentsSection
        }
        .padding(.top, Self.moreRowTop)
        // Room below the last row, so every row — the last one too — can
        // scroll up to the same spot. (A short More page couldn't scroll at
        // all, and the rows' scrolls fought the page's end.)
        .padding(.bottom, height - Self.moreRowTop)
        .frame(minHeight: height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            hint(viewModel.meta.isSeries ? "Episodes" : "Overview",
                 up: true, on: .more, y: TitleBlock.topHintY)
        }
    }

    /// Where a focused More row's title sits: the first row's place, below
    /// the hint.
    private static let moreRowTop = Spotlight.topPadding + Spotlight.labelHeight + 24

    /// Focus reached a More row: the page is More, and that row scrolls in.
    private func focusMoreRow(_ row: MoreRow) {
        page = .more
        moreRow = row
    }

    /// Name of the More page, after its first section that actually has
    /// content — so a hint never points at something that isn't there.
    /// Nil = no More page at all.
    private var morePageTitle: String? {
        // One name for the whole section (similar titles, collection, cast,
        // production, comments) — whenever any of it has content.
        let hasAny = (layout.detailShowMoreLikeThis && !viewModel.moreLikeThis.isEmpty)
            || (layout.detailShowCollection && viewModel.collection != nil
                && !viewModel.collectionParts.isEmpty)
            || (layout.detailShowCast && !(viewModel.crew + viewModel.cast).isEmpty)
            || (layout.detailShowProduction && !viewModel.companies.isEmpty)
            || (layout.detailShowComments && !viewModel.comments.isEmpty)
        return hasAny ? "More" : nil
    }

    /// Down from the buttons: land on an episode — the one last focused in
    /// the row, else the Play target (if it's in the shown season), else
    /// the season's first. Scroll it into place first so its cell exists.
    private func enterEpisodeRow() {
        guard !rowEpisodes.isEmpty else { return }
        // Deferred one turn: the engine's own move onto the chip must finish
        // before a programmatic focus change can win.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            rowFocus = .box
        }
    }

    /// Everything on the overview below the shared title block: just the
    /// buttons (the rest is in `aboutSection`, on the More page).
    private var headerExtras: some View {
        actionRow
            .padding(.leading, Spotlight.screenInset)
    }


    private func backToBillboard() {
        guard page == .overview else {
            actionFocus = .play
            return
        }
        guard swappedIn else { return }
        withAnimation(ModeSwap.out) { swappedIn = false }
        // The depth goes part-way back; Home (same image) finishes it.
        withAnimation(ModeSwap.depthLeaving) {
            depth = fromBox ? ModeSwap.boxDepthHandover : 1 - ModeSwap.depthHandover
            // (From a box: the scrim part-way back — Home finishes.)
            if fromBox { scrim = ModeSwap.boxScrimHandover }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ModeSwap.handoverDelay))
            onReturnToBillboard?()
        }
    }

    /// The title block's ratings row (nil = none).
    private var ratingsBadges: AnyView? {
        let entries = MDBListRatingsRow.entries(viewModel.mdbRatings, settings: mdblist.settings,
                                                imdbFallback: viewModel.meta.imdbRating)
        return entries.isEmpty ? nil : AnyView(MDBListRatingsRow(entries: entries))
    }

    /// Play/Resume (+ Start Over) + circular add / watched / rate / trailer.
    /// Its own focus section so Down/Up move cleanly to/from the rows below
    /// instead of the focus engine skipping a row.
    private var actionRow: some View {
            HStack(spacing: OrivioSpacing.md) {
                // Play is present from the FIRST frame, even before the
                // episode list has loaded and `seriesPlayTarget` can say
                // which episode it starts (a page without it let focus
                // settle elsewhere, then jumped). Pressing it early is not
                // lost: `pendingSeriesPlay` fires once the target lands.
                //
                // ONE pill at a time, always `pillWidth` wide, the others
                // circles: the group's edges never move — only where the
                // pill is inside it.
                let target = viewModel.meta.isSeries ? seriesPlayTarget : nil
                DetailActionButton(
                    icon: "play.fill", title: playTitle(target),
                    isPill: pillAction == .play, lit: litAction == .play, pillWidth: pillWidth,
                    action: {
                        if viewModel.meta.isSeries, target == nil { pendingSeriesPlay = .auto }
                        else { onPlay(viewModel.meta, target) }
                    },
                    // Hold Select: straight to the source list.
                    onHold: {
                        if viewModel.meta.isSeries, target == nil { pendingSeriesPlay = .manual }
                        else { onPlayManually(viewModel.meta, target) }
                    }
                )
                .focused($actionFocus, equals: .play)
                .modifier(DotGrow(shown: swappedIn))
                // Trailer mode: Up (nothing above) brings the page back.
                .onMoveCommand { direction in
                    if direction == .up, trailerMode { revealTrailerPage() }
                }
                // The other two are one focus section, so a vertical move
                // into the row resolves against the section as a unit
                // instead of picking whichever circle's centre is nearest
                // (tvOS picks a Down/Up target by horizontal CENTRE distance;
                // a bare circle used to beat Play and flash focus there
                // before the row's redirect pulled it back).
                HStack(spacing: OrivioSpacing.md) {
                    let saved = library.contains(viewModel.meta)
                    DetailActionButton(
                        icon: saved ? "checkmark" : "plus",
                        title: saved ? "In Library" : "Add to Library",
                        isPill: pillAction == .library, lit: litAction == .library, pillWidth: pillWidth,
                        // No toast: the button itself says it ("In Library").
                        action: { library.toggle(viewModel.meta) }
                    )
                    .focused($actionFocus, equals: .library)
                    .modifier(DotGrow(shown: swappedIn))
                    // Always there (the row never changes shape): without a
                    // trailer it says so.
                    DetailActionButton(
                        icon: "play.rectangle.fill", title: "Watch Trailer",
                        isPill: pillAction == .trailer, lit: litAction == .trailer, pillWidth: pillWidth,
                        action: {
                            if let trailer = viewModel.trailers.first { activeTrailer = trailer }
                            else { ToastCenter.shared.show("No trailer for this title", icon: "film") }
                        }
                    )
                    .focused($actionFocus, equals: .trailer)
                    .modifier(DotGrow(shown: swappedIn))
                }
                // Trailer mode: only Play stays (press it to play).
                .opacity(trailerMode ? 0 : 1)
                .animation(TrailerMode.fade, value: trailerMode)
                .focusSection()
                Spacer(minLength: 0)
            }
            .animation(DetailActionButton.open, value: pillAction)
            .animation(DetailActionButton.open, value: litAction)
            // Every title the row can show, measured once (hidden): the pill
            // width is the widest.
            .background {
                ZStack {
                    ForEach(rowTitles, id: \.self) { title in
                        DetailActionButton.titleText(title)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: MaxWidthKey.self, value: proxy.size.width)
                                }
                            }
                    }
                }
                .hidden()
            }
            .onPreferenceChange(MaxWidthKey.self) { maxTitleWidth = $0 }
            .onChange(of: actionFocus) { _, new in
                guard let new else { litAction = nil; return }
                Task { @MainActor in
                    try? await Task.sleep(for: DetailActionButton.paintDelay)
                    guard actionFocus == new else { return }
                    pillAction = new
                    litAction = new
                }
            }
            .padding(.top, OrivioSpacing.xs)
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
            // The enter-lands-on-Play redirect: focus arriving on any control
            // while the row previously held NOTHING gets moved to Play. Moves
            // WITHIN the row (old != nil) are left alone.
            .onChange(of: actionFocus) { old, new in
                interactionCount += 1
                if new != nil { page = .overview }
                // Deferred one turn: arming flips the teaser from unfocusable
                // to focusable, and doing that INSIDE the focus change that
                // put Play in focus is the "focusable set depends on focus"
                // trap this row's own comment bans — the engine can invalidate
                // the in-flight move and bounce it.
                if new == .play, !teaserArmed {
                    Task { @MainActor in teaserArmed = true }
                }
                // Only a USER move re-arms full-screen. Leaving full-screen
                // restores focus to Play programmatically; treating that as
                // interaction cleared the cooldown, so the page went back to
                // full-screen two seconds later and swallowed every other
                // press — the details page felt dead.
                if Date().timeIntervalSince(fullscreenExitedAt) > 1.0 {
                    fullscreenCooldown = false
                }
                if old == nil, let new, new != .play {
                    // DEFERRED, not immediate: setting @FocusState while the
                    // engine's own move is still in flight made it revert —
                    // Down from the synopsis went circle -> Play -> back to the
                    // synopsis, so the press appeared to do nothing at all.
                    // The icon it lands on never PAINTS in the meantime; see
                    // CircleIconLabel.
                    Task { @MainActor in
                        guard actionFocus != nil, actionFocus != .play else { return }
                        actionFocus = .play
                    }
                }
            }
    }

    private var playButtonTitle: String {
        let key = ProgressStore.key(metaID: viewModel.meta.id, video: nil)
        if let progress = progressStore.progress(for: key), progress.fraction > 0.02 {
            return "Resume"
        }
        return "Play"
    }

    /// Whether this episode has saved progress worth restarting from 0.
    private func episodeInProgress(_ episode: MetaVideo) -> Bool {
        guard let progress = progressStore.progress(for: episode.id) else { return false }
        return progress.fraction > 0.02 && progress.fraction < 0.95
    }

    /// For a series, the episode the Play button should start: an in-progress
    /// episode, else the next-up episode, else the very first — like the APK.
    private var seriesPlayTarget: MetaVideo? {
        let all = viewModel.allEpisodesInPlayOrder
        guard !all.isEmpty else { return nil }
        // The in-progress episode touched MOST RECENTLY — the one Continue
        // Watching resumes — not the first in play order, and not one the
        // viewer has moved past: when an episode at or after it has been
        // watched since, Play goes on to the next-up episode below, as Home's
        // row does (`supersededContinueRows`). First in play order would offer
        // "Resume S1:E3" to someone who left S1E3 half-watched a month ago and
        // has finished every episode through S2E2 since.
        var latest: (index: Int, progress: WatchProgress)?
        for (index, ep) in all.enumerated() {
            guard let p = progressStore.progress(for: ep.id), p.fraction > 0.02, p.fraction < 0.95 else { continue }
            if let current = latest, (current.progress.updatedAt, current.progress.id) >= (p.updatedAt, p.id) { continue }
            latest = (index, p)
        }
        if let latest {
            let movedPast = all[latest.index...].contains { ep in
                guard let mark = watched.items[WatchedItem.key(contentID: viewModel.meta.id,
                                                               season: ep.season ?? 0,
                                                               episode: ep.episode)] else { return false }
                return mark.watchedAt > latest.progress.updatedAt
            }
            if !movedPast { return all[latest.index] }
        }

        func isWatched(_ ep: MetaVideo) -> Bool {
            watched.isWatched(contentID: viewModel.meta.id, season: ep.season ?? 0, episode: ep.episode)
        }
        // Candidate unwatched episodes, honoring the "skip unaired" preference.
        let unwatched = all.filter { !isWatched($0) && (layout.showUnairedNextUp || $0.hasAired) }

        if layout.nextUpFromFurthestEpisode {
            // Next-up = the episode right after the FURTHEST watched one.
            if let furthestIndex = all.lastIndex(where: isWatched) {
                if let next = all[(furthestIndex + 1)...].first(where: {
                    layout.showUnairedNextUp || $0.hasAired
                }) { return next }
            }
        }
        if let firstUnwatched = unwatched.first { return firstUnwatched }
        return all.first
    }

    /// Blur an episode still when spoiler-blur is on and the episode is neither
    /// watched nor in progress.
    private func shouldBlurEpisode(_ episode: MetaVideo, season: Int) -> Bool {
        guard layout.blurUnwatchedEpisodes else { return false }
        let isWatched = watched.isWatched(contentID: viewModel.meta.id, season: season, episode: episode.episode)
        let inProgress = (progressStore.progress(for: episode.id)?.fraction ?? 0) > 0.02
        return !isWatched && !inProgress
    }

    /// The Play button's label on a show: just the episode ("S1:E1") — the
    /// ▶ says play; resume or not, it continues where you are.
    private func seriesPlayTitle(_ episode: MetaVideo) -> String {
        "S\(episode.season ?? 1):E\(episode.episode ?? 1)"
    }

    /// Play's title: "Play", on a show "Play S1:E1".
    private func playTitle(_ target: MetaVideo?) -> String {
        target.map { "Play \(seriesPlayTitle($0))" } ?? "Play"
    }

    /// Every title the row can show (for the pill width).
    private var rowTitles: [String] {
        [playTitle(viewModel.meta.isSeries ? seriesPlayTarget : nil),
         "Add to Library", "In Library", "Watch Trailer"]
    }

    private var pillWidth: CGFloat { DetailActionButton.pillWidth(title: maxTitleWidth) }

    // MARK: - Episode row

    /// What the row shows: the specials, then every regular episode in play
    /// order — ONE row, a season seam between each (Left from S1:E1 crosses
    /// into the specials).
    private var rowEpisodes: [MetaVideo] {
        let regular = viewModel.allEpisodesInPlayOrder
        let specials = regular.contains { $0.season == 0 } ? [] : viewModel.episodes(season: 0)
        return specials + regular
    }

    private var currentIndex: Int {
        min(episodeIndex, max(rowEpisodes.count - 1, 0))
    }

    private var currentEpisode: MetaVideo? {
        let list = rowEpisodes
        return list.indices.contains(currentIndex) ? list[currentIndex] : nil
    }

    private func episodesSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // The season selector, centred over the box: the current season
            // with ‹ ›, and a faded preview of the one before and after.
            // Up from the box focuses it; Left/Right switches season.
            if viewModel.meta.seasons.count > 1 {
                seasonSelector
                    .padding(.leading, Spotlight.screenInset)
            }

            if let episode = currentEpisode {
                ZStack(alignment: .topLeading) {
                    episodeStrip()
                        .frame(width: width - Spotlight.screenInset,
                               height: Spotlight.rowHeight, alignment: .topLeading)
                        .allowsHitTesting(false)
                    // The box: stationary, its card crossfading in place.
                    episodeBox()
                        .allowsHitTesting(false)
                    episodeFocusLayer(episode)
                }
                .frame(width: width - Spotlight.screenInset, alignment: .topLeading)
                .padding(.leading, Spotlight.screenInset)
                .opacity(rowFocus == nil ? 0.85 : 1)
                .animation(.easeOut(duration: 0.2), value: rowFocus == nil)

                episodeInfo(episode)
                    // Meta line + synopsis (the title is on the card now).
                    .frame(height: 170, alignment: .topLeading)
                    .padding(.leading, Spotlight.screenInset)
            } else if viewModel.isLoading {
                OrivioLoadingView(label: "Loading episodes")
                    .frame(height: Spotlight.rowHeight)
            }
        }
        .onChange(of: viewModel.selectedSeason) { _, newSeason in
            if let newSeason { Task { await viewModel.loadSeason(newSeason) } }
        }
        // A press landed on a side target: step, then hand focus straight
        // back to the box. Only a move that STARTED on the box steps —
        // arriving on a side target from elsewhere (Up from the cast row)
        // just settles on the box, on the episode you left.
        .onChange(of: rowFocus) { old, new in
            if new != nil { page = .episodes }
            guard let new, new != .box else { return }
            if old == .box { stepEpisode(by: new == .left ? -1 : 1) }
            rowFocus = .box
        }
    }

    /// The season selector's dots for the seasons after the next one.
    private static let seasonDot: CGFloat = 10
    private static let seasonMaxDots = 6

    /// The seasons in order, Specials first.
    private var orderedSeasons: [Int] {
        viewModel.meta.seasons.sorted { ($0 == 0 ? -1 : $0) < ($1 == 0 ? -1 : $1) }
    }

    /// The seasons as a small row, like the catalog rows: the current one at
    /// the box's left edge (large, white); before it the previous ones,
    /// smaller and dimmed, running off into the margin (only a sliver of
    /// the nearest shows); after it just the next one. Focused: the current
    /// season grows a little. On a change the row slides.
    private var seasonSelector: some View {
        let seasons = orderedSeasons
        let current = viewModel.selectedSeason ?? seasons.first ?? 1
        let i = seasons.firstIndex(of: current) ?? 0
        let prev = i > 0 ? seasons[i - 1] : nil
        let next = i + 1 < seasons.count ? seasons[i + 1] : nil
        // Laid out by the names' real widths: the current one at the box's
        // left edge, the next one a gap after it, the previous ones a gap
        // before it (and before each other), running off into the margin.
        // Each name slides to its spot on a change, and grows / shrinks (a
        // scale — font sizes don't animate). Focused: the current one grows
        // a little.
        let gap: CGFloat = 26
        let small: CGFloat = 20.0 / 26.0
        func w(_ k: Int) -> CGFloat { seasonWidths[seasons[k]] ?? 140 }
        func x(_ k: Int) -> CGFloat {
            if k == i { return 0 }
            if k > i {
                // (After the current one's width as drawn — grown when focused.)
                return w(i) * (seasonFocused ? 1.1 : 1) + gap
                    + (i + 1 ..< k).reduce(0) { $0 + w($1) * small + gap }
            }
            // Right edge a gap before the next one's (scaled) left edge;
            // the frame is the unscaled width, the scale keeps the right edge.
            let right = -gap - (k + 1 ..< i).reduce(0) { $0 + w($1) * small + gap }
            return right - w(k)
        }
        return ZStack(alignment: .leading) {
            ForEach(Array(seasons.enumerated()), id: \.element) { k, season in
                let isCurrent = k == i
                Text(seasonName(season).uppercased())
                    .font(.system(size: 26, weight: .bold))
                    .tracking(1.5)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(isCurrent ? AppGlass.text : AppGlass.text.opacity(0.4))
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: SeasonWidthKey.self,
                                                   value: [season: geo.size.width])
                        }
                    }
                    .scaleEffect(isCurrent ? (seasonFocused ? 1.1 : 1) : small,
                                 anchor: k < i ? .trailing : .leading)
                    .offset(x: x(k))
                    // Before: all (cut off by the screen edge). After: only
                    // the next one — the rest are dots (below).
                    .opacity(k <= i + 1 ? 1 : 0)
            }
            // More seasons than shown: a small glass dot for each after the
            // next one (at most `maxDots`, the last ones tapering — "and
            // more"). A season's dot becomes its name as it comes next.
            let dotsStart = i + 1 < seasons.count
                ? x(i + 1) + w(i + 1) * small + gap : 0
            ForEach(Array(seasons.enumerated()), id: \.element) { k, _ in
                let n = k - (i + 2)            // 0 = the first dot
                let shown = n >= 0 && n < Self.seasonMaxDots
                let taper: CGFloat = n >= Self.seasonMaxDots - 2
                    && seasons.count - (i + 2) > Self.seasonMaxDots ? (n == Self.seasonMaxDots - 1 ? 0.5 : 0.75) : 1
                let size = Self.seasonDot * taper
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: size, height: size)
                    .glassSurface(in: Circle())
                    .overlay { GlassRim(cornerRadius: size / 2, strength: 1.2) }
                    .frame(width: Self.seasonDot, height: Self.seasonDot)
                    .offset(x: dotsStart + CGFloat(max(n, 0)) * (Self.seasonDot + 12))
                    .opacity(shown ? 1 : 0)
            }
        }
        .onPreferenceChange(SeasonWidthKey.self) { widths in
            seasonWidths.merge(widths) { _, new in new }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.3), value: current)
        .animation(.easeOut(duration: 0.2), value: seasonFocused)
        .contentShape(Rectangle())
        .focusable()
        .focused($seasonFocused)
        .onChange(of: seasonFocused) { _, focused in
            guard focused else { return }
            // Down from the overview's buttons lands here first (it's in the
            // way): pass it on to the episode. Otherwise it's a real visit.
            if page == .overview { enterEpisodeRow() } else { page = .episodes }
        }
        // Left/Right: the season before / after (the row jumps with it).
        .onMoveCommand { direction in
            switch direction {
            case .left:  if let prev { switchSeason(to: prev, step: -1) }
            case .right: if let next { switchSeason(to: next, step: 1) }
            default: break
            }
        }
    }

    private func switchSeason(to season: Int, step: Int) {
        seasonStep = step
        jumpToSeason(season)
    }

    /// The episode row, exactly like Home's rows (all cards landscape, the
    /// box's size): the cards slide under the fixed box, the previous one
    /// peeking in at the left; between two seasons a glass SEAM card
    /// ("Season 2") takes a slot — crossed with Home's heavy resistance.
    private func episodeStrip() -> some View {
        let list = rowEpisodes
        let current = currentIndex
        let n = list.count
        let first = max(current - 2, 0)
        let last = min(current + 4, n - 1)
        let slot = Spotlight.boxWidth + Spotlight.spacing
        /// Season changes between `a` and `b` (a ≤ b): seam cards between.
        func seams(_ a: Int, _ b: Int) -> Int {
            guard b > a else { return 0 }
            return (a..<b).filter { list[$0].season != list[$0 + 1].season }.count
        }
        func x(_ k: Int) -> CGFloat {
            if k >= current { return CGFloat(k - current + seams(current, k)) * slot }
            return -CGFloat(current - k + seams(k, current)) * slot
        }
        return ZStack(alignment: .topLeading) {
            if n > 0 {
                ForEach(Array(first...max(first, last)), id: \.self) { k in
                    episodeCard(list[k], startsSeason: false)
                        .offset(x: x(k))
                        // The previous card peeks; older ones have slid away;
                        // the current one is under the box.
                        .opacity(k < current - 1 || k == current ? 0 : 1)
                }
                // The seam cards: in the slot before each season's first
                // episode.
                ForEach(Array(first...max(first, last)).filter {
                    $0 > 0 && list[$0 - 1].season != list[$0].season
                }, id: \.self) { k in
                    seasonSeamCard(list[k].season ?? 0)
                        .offset(x: x(k) - slot)
                        .opacity(k >= current ? 1 : 0)
                }
            }
        }
        // The resistance: the cards give a little.
        .offset(x: episodeNudge)
    }

    /// Between two seasons: a landscape glass card, "Season N" — pressed
    /// (like a glass button) while the row resists before crossing it.
    private func seasonSeamCard(_ season: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
        return ZStack {
            Color.clear.glassSurface(in: shape)
            VStack(spacing: 10) {
                Text(seasonName(season))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(AppGlass.text)
                let count = viewModel.episodes(season: season).count
                if count > 0 {
                    Text(count == 1 ? "1 Episode" : "\(count) Episodes")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppGlass.textMuted)
                }
            }
        }
        .frame(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
        .overlay { GlassRim(cornerRadius: Spotlight.cornerRadius) }
        .overlay { shape.fill(Color.white.opacity(seasonSeamPressed ? Spotlight.seamPressGlow : 0)) }
        .scaleEffect(seasonSeamPressed ? Spotlight.seamPressScale : 1)
    }

    /// The box: stationary; the current episode's card crossfades in place
    /// (its neighbours mounted invisibly, so a step is instant).
    private func episodeBox() -> some View {
        let list = rowEpisodes
        let current = currentIndex
        let window = list.isEmpty ? [] : Array(max(0, current - 1)...min(list.count - 1, current + 1))
        return ZStack {
            Color.black
            ForEach(window, id: \.self) { k in
                episodeCard(list[k], startsSeason: false)
                    .opacity(k == current ? 1 : 0)
                    .zIndex(k == current ? 1 : 0)
            }
        }
        .frame(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
        .overlay { GlassRim(cornerRadius: Spotlight.cornerRadius) }
    }

    /// Brightness of the text on the episode cards.

    private func episodeCard(_ episode: MetaVideo, startsSeason: Bool) -> some View {
        let season = episode.season ?? 0
        let extra = episode.episode.flatMap { viewModel.episodeExtras[season]?[$0] }
        // TMDB's still in full resolution first: the add-on's thumbnail is
        // often small, and these cards are big.
        let image = TMDBService.originalSize(extra?.still) ?? episode.thumbnail
            ?? viewModel.meta.background ?? viewModel.meta.poster
        let shape = RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
        let progress = progressStore.progress(for: episode.id)?.fraction ?? 0
        let isDone = isWatched(episode, season: season)

        return ZStack(alignment: .bottomLeading) {
            EpisodeArt(url: image, blurred: shouldBlurEpisode(episode, season: season))
                .frame(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
            // The same dark foot as Continue Watching's cards.
            LinearGradient(colors: [.clear, .black.opacity(Spotlight.continueFootOpacity)],
                           startPoint: Spotlight.continueFootStart, endPoint: .bottom)
            // The card's STATE, one line — Continue Watching's (its identity,
            // the title, is under the box).
            episodeState(episode, progress: progress, watched: isDone)
                .padding(.horizontal, Spotlight.progressBarInset)
                .padding(.bottom, Spotlight.progressBarBottomInset)
        }
        .frame(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
        .clipShape(shape)
    }

    /// An episode card's state line, like Continue Watching's: the episode
    /// on the left, its status / time on the right — "S1:E4 ▬▬▬░░ 20m
    /// left" in progress; else "S1:E4 … ✓ Watched" / "… Airs Fri" / "… 45m".
    @ViewBuilder
    private func episodeState(_ episode: MetaVideo, progress: Double, watched: Bool) -> some View {
        let number = "S\(episode.season ?? 0):E\(episode.episode ?? 0)"
        let inProgress = !watched && progress > 0.02 && progress < 0.95
        HStack(spacing: Spotlight.continueStateGap) {
            stateText(number)
            if inProgress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Spotlight.progressTrack)
                        Capsule().fill(Spotlight.progressFill)
                            .frame(width: max(proxy.size.width * progress,
                                              Spotlight.continueProgressBarHeight))
                    }
                    .frame(height: Spotlight.continueProgressBarHeight)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: Spotlight.continueProgressBarHeight)
                if let left = progressStore.progress(for: episode.id)?.remainingTimeText {
                    stateText("\(left) left")
                }
            } else {
                // Left: which episode; right: its status / time — the same
                // spot as "20m left" in progress.
                Spacer(minLength: 0)
                if watched {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 18, weight: .bold))
                        stateText("Watched")
                    }
                    .foregroundStyle(AppGlass.text)
                } else if let airs = episode.airCountdownText {
                    stateText(airs)
                } else {
                    let season = episode.season ?? 0
                    let extra = episode.episode.flatMap { viewModel.episodeExtras[season]?[$0] }
                    if let length = episodeLength(episode, extra: extra) { stateText(length) }
                }
            }
        }
    }

    private func stateText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Spotlight.continueStateSize, weight: .semibold))
            .foregroundStyle(AppGlass.text)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            .lineLimit(1)
            .fixedSize()
    }

    /// The stationary spot: outline, the focusable box, its side targets.
    private func episodeFocusLayer(_ episode: MetaVideo) -> some View {
        let count = rowEpisodes.count
        return HStack(spacing: 0) {
            // (Always: at the row's ends a press bounces.)
            rowSentinel(.left, enabled: !rowEpisodes.isEmpty, width: 20)
            Color.clear
                .frame(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
                .overlay {
                    // The same glass focus rim as Home's box.
                    GlassFocusRim(cornerRadius: Spotlight.cornerRadius,
                                  lineWidth: Spotlight.outlineWidth)
                        .opacity(rowFocus != nil ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: rowFocus != nil)
                }
                .contentShape(Rectangle())
                .focusable()
                .focused($rowFocus, equals: .box)
                .onTapGesture { onPlay(viewModel.meta, episode) }
                // ONE menu, content depends on the episode (not swapped
                // modifiers — that would rebuild the box and drop focus).
                .contextMenu { episodeMenu(episode) }
            rowSentinel(.right, enabled: count > 0, width: 1)
        }
        .padding(.leading, -20)
    }

    @ViewBuilder
    private func rowSentinel(_ slot: RowSlot, enabled: Bool, width: CGFloat) -> some View {
        if enabled {
            Color.clear
                .frame(width: width, height: Spotlight.rowHeight)
                .focusable()
                .focused($rowFocus, equals: slot)
        } else {
            Color.clear.frame(width: width, height: Spotlight.rowHeight)
        }
    }

    @ViewBuilder
    private func episodeMenu(_ episode: MetaVideo) -> some View {
        let season = episode.season ?? 0
        if autoLinkOn {
            Button { onPlayManually(viewModel.meta, episode) } label: {
                Label("Play Manually", systemImage: "list.and.film")
            }
        }
        Button { toggleWatched(episode, season: season) } label: {
            Label(isWatched(episode, season: season) ? "Mark as Unwatched" : "Mark as Watched",
                  systemImage: isWatched(episode, season: season) ? "eye.slash" : "checkmark.circle")
        }
        Button { markSeasonWatched(season) } label: {
            Label(season == 0 ? "Mark Specials Watched" : "Mark Season \(season) Watched",
                  systemImage: "checkmark.circle.fill")
        }
    }

    /// Under the row, for the episode in the box: "S1:E4 · Title", then air
    /// date / rating / time left, then the synopsis. Crossfades per step.
    private func episodeInfo(_ episode: MetaVideo) -> some View {
        // Its identity: the title, then the synopsis. (Which episode, how
        // long / how far / watched / when it airs: in the card. No air date
        // for past episodes, no rating — it hints at the "big" ones.)
        return VStack(alignment: .leading, spacing: 10) {
            Text(episode.title.flatMap { $0.isEmpty ? nil : $0 }
                 ?? episode.episode.map { "Episode \($0)" } ?? "Episode")
                .font(FusionType.bodyText(theme.font))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(FusionType.bodyText(theme.font))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(Spotlight.episodeDescriptionLines)
                    .frame(maxWidth: Spotlight.episodeDescriptionWidth, alignment: .leading)
            }
        }
        .id(episode.id)
        .transition(.opacity.animation(Spotlight.textFade))
    }
    
    private func stepEpisode(by delta: Int) {
        let list = rowEpisodes
        guard !list.isEmpty, !episodeWrapping else { return }
        pressEpisodeChevron(delta)
        let next = currentIndex + delta
        // The row's ends: resistance, then back (the series doesn't loop).
        guard list.indices.contains(next) else { bounceEpisodes(delta); return }
        let crossesSeam = list[currentIndex].season != list[next].season
        if crossesSeam {
            // Across a season seam: Home's heavy step — the cards resist (and
            // the seam card is pressed), then the row slides on past it.
            episodeWrapping = true
            withAnimation(Spotlight.wrapPress) {
                episodeNudge = -CGFloat(delta) * Spotlight.wrapNudge
                seasonSeamPressed = true
            }
            Task {
                try? await Task.sleep(for: Spotlight.wrapHold)
                withAnimation(.smooth(duration: 0.25)) { seasonSeamPressed = false }
                withAnimation(Spotlight.wrapSlide) {
                    episodeNudge = 0
                    episodeIndex = next
                }
                seasonStep = delta > 0 ? 1 : -1
                withAnimation(.smooth(duration: 0.3)) { syncSeasonToCurrent() }
                try? await Task.sleep(for: .seconds(0.3))
                episodeWrapping = false
            }
        } else {
            withAnimation(Spotlight.slide) { episodeIndex = next }
            syncSeasonToCurrent()
        }
        // Crossing into a season whose ratings / air dates / stills aren't
        // loaded yet: fetch them a few episodes ahead of the boundary.
        for offset in [1, 3] where list.indices.contains(next + offset) {
            if let s = list[next + offset].season { Task { await viewModel.loadSeason(s) } }
        }
    }

    /// The end of the episode row: the cards give, then spring back.
    private func bounceEpisodes(_ delta: Int) {
        episodeWrapping = true
        withAnimation(Spotlight.wrapPress) { episodeNudge = -CGFloat(delta) * Spotlight.wrapNudge }
        Task {
            try? await Task.sleep(for: Spotlight.wrapHold)
            withAnimation(Spotlight.endBounce) { episodeNudge = 0 }
            try? await Task.sleep(for: .seconds(0.15))
            episodeWrapping = false
        }
    }

    /// The pressed direction's ‹ ›: a quick press and release.
    private func pressEpisodeChevron(_ delta: Int) {
        let side = delta > 0 ? 1 : -1
        withAnimation(.easeOut(duration: 0.08)) { episodePressedChevron = side }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.smooth(duration: 0.25)) {
                if episodePressedChevron == side { episodePressedChevron = 0 }
            }
        }
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

    /// The season selector follows the episode in the box.
    private func syncSeasonToCurrent() {
        guard let season = currentEpisode?.season,
              viewModel.selectedSeason != season else { return }
        viewModel.selectedSeason = season
    }

    /// The selector: jump the row to that season's first episode.
    private func jumpToSeason(_ season: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            episodeIndex = rowEpisodes.firstIndex { $0.season == season } ?? 0
        }
        viewModel.selectedSeason = season
    }

    /// Mark every AIRED episode of a season watched (unaired ones would be
    /// pushed to Trakt/SIMKL as real plays and wreck the new-episode badge).
    private func markSeasonWatched(_ season: Int) {
        for episode in viewModel.episodes(season: season) where episode.hasAired && !watched.isWatched(
            contentID: viewModel.meta.id, season: episode.season ?? season, episode: episode.episode
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

    /// Episode caption: the overview if present, otherwise the localized air
    /// date. An episode that has not aired yet leads with when it WILL — the
    /// overview is written for the episode, not for the wait.
    private func episodeSubtitle(_ episode: MetaVideo, extra: TMDBService.EpisodeExtra?) -> String? {
        let air = episode.airCountdownText
        if let overview = episode.overview, !overview.isEmpty {
            return air.map { "\($0) · \(overview)" } ?? overview
        }
        return air ?? DateFormat.releaseDate(extra?.airDate ?? episode.released)
    }

    /// Aired episodes in this season the viewer has not watched.
    private func episodesLeft(season: Int) -> Int {
        viewModel.episodes(season: season).filter {
            $0.hasAired && !watched.isWatched(contentID: viewModel.meta.id,
                                              season: $0.season ?? season,
                                              episode: $0.episode)
        }.count
    }

    private func episodeTitle(_ episode: MetaVideo) -> String {
        var label = ""
        if let number = episode.episode { label = "\(number). " }
        return label + (episode.title ?? "Episode")
    }

    private func episodeCastLine(_ cast: [TMDBService.CastMember]?) -> String? {
        guard let names = cast?.prefix(3).map(\.name), !names.isEmpty else { return nil }
        return "Cast: \(names.joined(separator: ", "))"
    }

    // MARK: - Cast

    @ViewBuilder
    private var castSection: some View {
        let people = viewModel.crew + viewModel.cast
        if layout.detailShowCast, !people.isEmpty {
            moreSection("Cast & Crew", row: .cast) {
                SlidingFocusRow(items: people, itemSize: CGSize(width: 160, height: 160),
                                rowHeight: 250, focusCorner: 80,
                                onSelect: { onSelectPerson($0.id, $0.name) },
                                onFocus: { if $0 { focusMoreRow(.cast) } }) { member, focused in
                    PersonCard(member: member, focused: focused)
                }
            }
        }
    }

    // MARK: - Collection ("belongs to")

    @ViewBuilder
    private var collectionSection: some View {
        if layout.detailShowCollection, let collection = viewModel.collection,
           !viewModel.collectionParts.isEmpty {
            moreSection(collection.name, row: .collection) {
                posterRow(viewModel.collectionParts, row: .collection)
            }
        }
    }

    // MARK: - More Like This

    @ViewBuilder
    private var moreLikeThisSection: some View {
        if layout.detailShowMoreLikeThis, !viewModel.moreLikeThis.isEmpty {
            moreSection("More Like This", row: .moreLikeThis) {
                posterRow(viewModel.moreLikeThis, row: .moreLikeThis)
            }
        }
    }

    // MARK: - Production companies

    @ViewBuilder
    private var companiesSection: some View {
        if layout.detailShowProduction, !viewModel.companies.isEmpty {
            moreSection("Production", row: .companies) {
                SlidingFocusRow(items: viewModel.companies, itemSize: CGSize(width: 220, height: 110),
                                rowHeight: 110, focusCorner: 14,
                                onSelect: { onSelectCompany($0.id, $0.name) },
                                onFocus: { if $0 { focusMoreRow(.companies) } }) { company, focused in
                    CompanyPlate(company: company, focused: focused)
                }
            }
        }
    }

    /// A More-page section: its title, then its row.
    private func moreSection<Content: View>(_ title: String, row: MoreRow,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
            DetailRowHeader(title: title)
            content()
                .padding(.leading, Spotlight.screenInset)
        }
        .modifier(MoreRowAnchor(row: row, top: Self.moreRowTop))
    }

    /// Titles as portrait posters on the sliding row (Home's look).
    private func posterRow(_ items: [MetaItem], row: MoreRow) -> some View {
        SlidingFocusRow(items: items, itemSize: CGSize(width: 200, height: 300), rowHeight: 300,
                        onSelect: { onSelectItem($0) },
                        onFocus: { if $0 { focusMoreRow(row) } },
                        menu: { AnyView(posterMenu($0)) }) { item, focused in
            MorePoster(item: item, focused: focused)
        }
    }

    /// Hold Select on a More poster: Home's poster menu (Details, Library,
    /// Watched for movies).
    @ViewBuilder
    private func posterMenu(_ item: MetaItem) -> some View {
        Button { onSelectItem(item) } label: {
            Label("Go to Details", systemImage: "info.circle")
        }
        Button { library.toggle(item) } label: {
            Label(library.contains(item) ? "Remove from Library" : "Add to Library",
                  systemImage: library.contains(item) ? "bookmark.slash" : "bookmark")
        }
        if !item.isSeries {
            Button { watched.toggleMovie(item) } label: {
                Label(watched.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched",
                      systemImage: watched.isWatched(item) ? "eye.slash" : "checkmark.circle")
            }
        }
    }

    // MARK: - Comments (Trakt)

    @ViewBuilder
    private var commentsSection: some View {
        if layout.detailShowComments, !viewModel.comments.isEmpty {
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                DetailRowHeader(title: "Comments")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
                        ForEach(viewModel.comments) { comment in
                            CommentCard(comment: comment, onFocus: { focusMoreRow(.comments) })
                        }
                    }
                    .padding(.horizontal, Spotlight.screenInset)
                    .padding(.vertical, OrivioSpacing.md)
                }
                .scrollClipDisabled()
                // The page's scrollDisabled reaches in here; this row scrolls.
                .scrollDisabled(false)
            }
            .modifier(MoreRowAnchor(row: .comments, top: Self.moreRowTop))
            .focusSection()
        }
    }
}

/// A button style with NO chrome at all — used by the full-screen trailer's
/// invisible input-capture button.
private struct InertButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// One episode in the season row. The still is the only thing inside the
/// button, so the native platter raises and sheens JUST the artwork; the
/// caption is a sibling below it and stays put, easing down only far enough to
/// hold its gap as the platter grows the still downward. Putting the caption
/// inside the button instead bridged art and text into one lifting slab.
private struct EpisodeCell: View {
    let imageURL: String?
    let title: String
    var subtitle: String?
    var progress: Double?
    var isWatched: Bool
    var rating: String?
    var detailLine: String?
    /// "Airs in 3 days" / "Airs tomorrow" for an episode that has not aired yet.
    var unreleasedText: String?
    var blurImage: Bool
    let onPlay: () -> Void
    let onToggleWatched: () -> Void
    /// Present only while an auto-select feature is armed: the hold menu's
    /// "Play Manually" escape hatch to the full source list for THIS episode.
    var onPlayManually: (() -> Void)?
    /// Called when this episode's button GAINS focus. `.focused(...)` on the
    /// whole cell never fires (the cell is a VStack, only the Button inside
    /// is focusable), so the row learns about focus through this instead.
    var onFocus: () -> Void = {}
    /// Lets the page put focus on THIS episode programmatically.
    let episodeID: String
    let focusBinding: FocusState<String?>.Binding

    /// Focus mirrored out of the button: a sibling caption cannot read
    /// `\.isFocused`, which only resolves inside the focusable view.
    @State private var focused = false
    @State private var rawFocused = false

    private static let cardWidth: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            Button(action: onPlay) {
                LandscapeCard(
                    imageURL: imageURL,
                    title: title,
                    subtitle: subtitle,
                    progress: progress,
                    watched: isWatched,
                    rating: rating,
                    width: Self.cardWidth,
                    subtitleBehavior: .readableOnFocus,
                    detailLine: detailLine,
                    remainingText: unreleasedText,
                    blurImage: blurImage,
                    showsCaption: false
                )
                .onFocusChange { rawFocused = $0; if $0 { onFocus() } }
            }
            // The same focus treatment every other card in the app gets — the
            // native platter, or a scale lift when "Card wiggle & lift" is off.
            // It was PlainCardButtonStyle, which is neither, and LandscapeCard
            // suppresses its own focus ring whenever the GLOBAL parallax/zoom
            // settings are on (assuming a platter is carrying the highlight).
            // With the defaults that left a focused episode with no ring, no
            // platter and no lift — only the caption brightening — so you could
            // not tell which episode you were on.
            .buttonStyle(DelayedLiftCardButtonStyle())
            .focused(focusBinding, equals: episodeID)
            // Hold Select on an episode to flip its watched state without
            // opening it — and, when auto-select is armed, to reach the manual
            // source list (a plain press auto-picks a link).
            .contextMenu {
                if let onPlayManually {
                    Button(action: onPlayManually) {
                        Label("Play Manually", systemImage: "list.and.film")
                    }
                }
                Button(action: onToggleWatched) {
                    Label(isWatched ? "Mark as Unwatched" : "Mark as Watched",
                          systemImage: isWatched ? "eye.slash" : "checkmark.circle")
                }
            }

            LandscapeCardCaption(
                title: title,
                subtitle: subtitle,
                detailLine: detailLine,
                width: Self.cardWidth,
                subtitleBehavior: .readableOnFocus,
                isFocused: focused,
                lowered: focused
            ).task(id: rawFocused) {
                guard rawFocused else { focused = false; return }
                try? await Task.sleep(for: episodeLiftDelay)
                if !Task.isCancelled { focused = true }
            }
        }
    }
}

// MARK: - The More page's rows

/// The More page's rows, as scroll targets.
enum MoreRow: Hashable { case moreLikeThis, collection, cast, companies, comments }

/// The scroll target of a More row: an invisible strip standing `top`
/// ABOVE the row, so scrolling it to the top puts the row's title where
/// the first row's is (below the hint) — every row lands in one place.
private struct MoreRowAnchor: ViewModifier {
    let row: MoreRow
    let top: CGFloat

    func body(content: Content) -> some View {
        content.background(alignment: .top) {
            Color.clear
                .frame(height: top)
                .alignmentGuide(.top) { $0[.bottom] }
                .id(row)
        }
    }
}

/// Home's motion language, compact: ONE focus position at the row's start
/// that never moves — the items slide under it on Left/Right (the previous
/// one peeking into the margin); at the ends, the resistance nudge. The
/// focused item keeps its shape: the glass focus rim and a slight lift.
/// The whole row is the focus target (Up/Down enter it anywhere).
struct SlidingFocusRow<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let itemSize: CGSize
    /// The row's height (cards with captions are taller than `itemSize`).
    var rowHeight: CGFloat
    var spacing: CGFloat = 28
    /// The focus rim's corner radius (half the width: a circle).
    var focusCorner: CGFloat = Spotlight.cornerRadius
    let onSelect: (Item) -> Void
    var onFocus: (Bool) -> Void = { _ in }
    /// The hold-Select menu for the current item (nil: none).
    var menu: ((Item) -> AnyView)? = nil
    @ViewBuilder let card: (Item, _ focused: Bool) -> Card

    @State private var index = 0
    @State private var nudge: CGFloat = 0
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        let slot = itemSize.width + spacing
        let first = max(index - 2, 0)
        let last = min(index + 9, items.count - 1)
        ZStack(alignment: .topLeading) {
            if !items.isEmpty {
                // The cards: they slide UNDER the box (the current one is
                // hidden beneath it, the previous one comes out on the left
                // and peeks) — and they alone give at the ends.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(first...max(first, last)), id: \.self) { k in
                        card(items[k], false)
                            .frame(width: itemSize.width, alignment: .top)
                            .offset(x: CGFloat(k - index) * slot)
                            .opacity(k < index - 1 || k == index ? 0 : 1)
                    }
                }
                .offset(x: nudge)

                // The box: STATIONARY at the focus position. Its item
                // crossfades in place (the neighbours mounted invisibly);
                // the focus rim is part of it, so it never leaves its item.
                ZStack(alignment: .top) {
                    ForEach(Array(max(index - 1, 0)...min(index + 1, items.count - 1)), id: \.self) { k in
                        card(items[k], focused && k == index)
                            .frame(width: itemSize.width, alignment: .top)
                            .opacity(k == index ? 1 : 0)
                            .zIndex(k == index ? 1 : 0)
                    }
                }
                .overlay(alignment: .top) {
                    GlassFocusRim(cornerRadius: focusCorner, lineWidth: Spotlight.outlineWidth)
                        .frame(width: itemSize.width, height: itemSize.height)
                        .opacity(focused ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: focused)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in onFocus(isFocused) }
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .onTapGesture { if items.indices.contains(index) { onSelect(items[index]) } }
        // On the row itself — the focused view; tvOS won't present a menu
        // from a view that isn't. Its content follows `index`.
        .contextMenu {
            if let menu, items.indices.contains(index) { menu(items[index]) }
        }
    }

    private func step(_ delta: Int) {
        guard !busy, !items.isEmpty else { return }
        let next = index + delta
        guard items.indices.contains(next) else {
            // The end: resistance, then back.
            busy = true
            withAnimation(Spotlight.wrapPress) { nudge = -CGFloat(delta) * Spotlight.wrapNudge * 0.6 }
            Task {
                try? await Task.sleep(for: Spotlight.wrapHold)
                withAnimation(Spotlight.endBounce) { nudge = 0 }
                try? await Task.sleep(for: .seconds(0.15))
                busy = false
            }
            return
        }
        withAnimation(Spotlight.slide) { index = next }
    }
}

/// A title on the More page: a portrait poster with the glass rim (the
/// focus rim and a lift when focused).
private struct MorePoster: View {
    let item: MetaItem
    let focused: Bool

    var body: some View {
        RemoteImage(url: item.poster ?? item.background, maxDimension: 300)
            .frame(width: 200, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
            .overlay { GlassRim(cornerRadius: Spotlight.cornerRadius) }
    }
}

/// A person: a round portrait with the glass rim, name and role below.
private struct PersonCard: View {
    let member: TMDBService.CastMember
    let focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            RemoteImage(url: member.profileURL, maxDimension: 160)
                .frame(width: 160, height: 160)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
                .overlay { GlassRim(cornerRadius: 80) }
            Text(member.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(focused ? AppGlass.text : AppGlass.textMuted)
                .lineLimit(1)
            if let role = member.character, !role.isEmpty {
                Text(role)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppGlass.textMuted.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(width: 180)
        .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// A production company: its logo on a light plate (logos are mostly dark)
/// with the glass rim.
private struct CompanyPlate: View {
    let company: TMDBService.Company
    let focused: Bool

    var body: some View {
        RemoteImage(url: company.logoURL, contentMode: .fit, maxDimension: 180)
            .frame(width: 180, height: 80)
            .frame(width: 220, height: 110)
            .background(Color.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { GlassRim(cornerRadius: 14) }
    }
}

/// A single Trakt comment card. Spoilers stay hidden until focused.
struct CommentCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let comment: TraktService.Comment
    var onFocus: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            HStack(spacing: OrivioSpacing.sm) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textTertiary)
                Text(comment.user)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 14))
                    Text("\(comment.likes)").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(theme.palette.textTertiary)
            }
            if comment.spoiler && !isFocused {
                Text("Spoiler — focus to reveal")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(theme.palette.secondary)
            } else {
                Text(comment.text)
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(6)
            }
        }
        .padding(OrivioSpacing.lg)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
        .focusable()
        .focusLift(OrivioFocus.row, isFocused)
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
    }
}

/// Circular icon button used for the Detail action row (add / watched / trailer),
/// matching the APK's dark round buttons that fill with the accent on focus.
/// Whether the action buttons use the SYSTEM's Liquid Glass (tvOS 26+,
/// on boxes that can afford it) — Apple's material with its native focus
/// behaviour. Otherwise the app's own chrome is the fallback.
enum DetailGlass {
    /// The buttons in Liquid Glass at all. Off: the plain style — a light
    /// translucent fill with the glass rim at rest, white with dark content
    /// on focus. (Glass flickered as the buttons faded in on the billboard
    /// ⇄ Details swap: it renders differently below full opacity.)
    static let buttonsUseGlass = false
    /// The SYSTEM glass buttons — same rule as every other glass element
    /// (see `AppGlass`), when glass is on at all.
    static var available: Bool { buttonsUseGlass && AppGlass.isReal }
}

extension View {
    /// The Detail buttons' own chrome (not the system glass style): glass
    /// at rest when `DetailGlass.buttonsUseGlass`, else the plain fill with
    /// the rim; the focused fill is drawn by the caller.
    @ViewBuilder
    func detailButtonRest<S: Shape>(_ atRest: Bool, in shape: S, rimCorner: CGFloat) -> some View {
        if DetailGlass.buttonsUseGlass {
            liquidGlassIf(atRest, in: shape)
        } else {
            background { if atRest { shape.fill(Color.white.opacity(0.16)) } }
                .overlay { if atRest { GlassRim(cornerRadius: rimCorner) } }
        }
    }
}




/// A Detail button's arrival from the billboard: it appears as a small dot
/// and swells into its shape with a liquid spring (a little overshoot),
/// left to right; leaving, it shrinks back into a dot and goes. Plain
/// buttons only — glass flickers under a changing opacity.
struct DotGrow: ViewModifier {
    let shown: Bool

    static let dotScale: CGFloat = 0.14
    /// One spring for all — they grow together, at the same pace.
    static let grow: Animation = .spring(response: 0.42, dampingFraction: 0.62)

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : Self.dotScale)
            .animation(shown ? Self.grow : ModeSwap.out, value: shown)
            .opacity(shown ? 1 : 0)
            .animation(shown ? ModeSwap.fadeIn : ModeSwap.fadeOut, value: shown)
    }
}

/// A Detail button: a circle with its icon, or — the row's one pill —
/// `pillWidth` wide with its title too (white while focused). The row
/// decides which is the pill; every pill is equally wide, so the row's
/// edges never move. Plain, not glass (see `DetailGlass`). `onHold`:
/// holding Select for half a second runs it instead of the action (a press
/// that became a hold never also taps).
struct DetailActionButton: View {
    let icon: String
    let title: String
    let isPill: Bool
    let lit: Bool
    let pillWidth: CGFloat
    let action: () -> Void
    var onHold: (() -> Void)? = nil

    @State private var didHold = false
    /// This title's own width, measured — its room animates 0 → this as
    /// one number (the icon + title pair stays centred in the pill).
    @State private var ownTitleWidth: CGFloat = 0

    static let paintDelay = Duration.milliseconds(50)
    /// Opening / closing: one calm curve, no bounce.
    static let open: Animation = .easeInOut(duration: 0.24)
    static let iconBox: CGFloat = 30
    static let inset: CGFloat = (detailButtonSize - iconBox) / 2
    static let titleGap: CGFloat = 12

    static func titleText(_ title: String) -> some View {
        Text(title).font(.system(size: 26, weight: .semibold)).lineLimit(1).fixedSize()
    }

    static func pillWidth(title: CGFloat) -> CGFloat {
        inset + iconBox + titleGap + title + inset
    }

    var body: some View {
        Button {
            if didHold { didHold = false; return }
            action()
        } label: {
            HStack(spacing: isPill ? Self.titleGap : 0) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: Self.iconBox)
                // Its room opens with the pill (0 → its width), centred —
                // one motion, nothing hanging outside.
                Self.titleText(title)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { ownTitleWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, w in ownTitleWidth = w }
                        }
                    }
                    .frame(width: isPill ? ownTitleWidth : 0, alignment: .leading)
                    .clipped()
                    .opacity(isPill ? 1 : 0)
            }
            .foregroundStyle(lit ? AppGlass.textOnFocus : AppGlass.text)
            .frame(width: isPill ? pillWidth : detailButtonSize, height: detailButtonSize)
            .clipShape(Capsule())
            .background { Capsule().fill(lit ? Color.white : Color.white.opacity(0.16)) }
            .overlay { if !lit { GlassRim(cornerRadius: detailButtonSize / 2) } }
        }
        .buttonStyle(DetailHoldButtonStyle(onHold: onHold, didHold: $didHold))
    }
}

private struct MaxWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Watches the press; still down after `holdAfter` → the hold. (After
/// NuvioTVOS's Play button — no context menu, so no minimum width either.)
private struct DetailHoldButtonStyle: ButtonStyle {
    let onHold: (() -> Void)?
    @Binding var didHold: Bool

    static let holdAfter: Duration = .milliseconds(500)

    func makeBody(configuration: Configuration) -> some View {
        HoldWatcher(configuration: configuration, onHold: onHold, didHold: $didHold)
    }

    private struct HoldWatcher: View {
        let configuration: ButtonStyle.Configuration
        let onHold: (() -> Void)?
        @Binding var didHold: Bool
        @State private var holdTask: Task<Void, Never>?

        var body: some View {
            configuration.label
                .cardPressDip(configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    holdTask?.cancel()
                    holdTask = nil
                    guard pressed, let onHold else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: DetailHoldButtonStyle.holdAfter)
                        guard !Task.isCancelled else { return }
                        didHold = true
                        onHold()
                        // A release that never arrives must not eat the
                        // next real tap.
                        try? await Task.sleep(for: .seconds(1))
                        didHold = false
                    }
                }
        }
    }
}


/// The hero pill chrome, shared by the detail page's primary action.
struct DetailPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        @EnvironmentObject private var theme: ThemeManager
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration

        /// The same chrome as the round buttons beside it: Liquid Glass at
        /// rest, the accent fill + lift on focus. (It used to be a solid
        /// light pill at rest with a glow on focus — the odd one out.)
        var body: some View {
            let plain = !DetailGlass.buttonsUseGlass
            configuration.label
                .foregroundStyle(isFocused ? (plain ? AppGlass.textOnFocus : theme.palette.onSecondary)
                                 : theme.palette.textPrimary)
                .padding(.horizontal, 36)
                .frame(height: detailButtonSize)
                .background {
                    if isFocused { Capsule().fill(plain ? Color.white : theme.palette.secondary) }
                }
                .detailButtonRest(!isFocused, in: Capsule(), rimCorner: detailButtonSize / 2)
                // The round buttons' lift (`.control`), not the bigger card
                // lift — every control in the row grows by the same amount.
                .focusLift(OrivioFocus.control, isFocused)
                .cardPressDip(configuration.isPressed)
        }
    }
}


// MARK: - Full description overlay

/// The truncated synopsis on the hero, clickable: opens a full-screen
/// overlay with the complete text (the Android app's scrollable
/// hero-description). Brightens on focus so it reads as selectable.
private struct DescriptionTeaser: View {
    @EnvironmentObject private var theme: ThemeManager
    let text: String
    let title: String
    var onFocusChanged: (Bool) -> Void = { _ in }
    @State private var showFull = false

    var body: some View {
        Button { showFull = true } label: {
            TeaserLabel(text: text, onFocusChanged: onFocusChanged)
        }
        .buttonStyle(PlainCardButtonStyle())
        // No .onMoveCommand redirect here. It set `actionFocus = .play` while
        // the engine's own Down was still in flight, and the engine won: focus
        // went to a circle icon anyway, then the action row's entry redirect
        // moved it to Play, then the whole update reverted to the teaser — so
        // pressing Down on the synopsis LOOKED like it did nothing. The row's
        // redirect (deferred by one turn) is the single owner of that move now.
        .fullScreenCover(isPresented: $showFull) {
            DescriptionOverlay(title: title, text: text) { showFull = false }
                .environmentObject(theme)
        }
    }
}

private struct TeaserLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let text: String
    var onFocusChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Text(text)
            .font(.system(size: 25))
            .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
            .lineLimit(4)
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Soft glass highlight on focus — reads as selectable without
            // the old solid accent slab shouting over the art.
            .liquidGlassIf(isFocused, in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? Color.white.opacity(0.35) : .clear, lineWidth: 2)
            )
            .padding(.horizontal, -14)   // keep the resting text aligned as before
            .onChange(of: isFocused) { _, focused in onFocusChanged(focused) }
    }
}

/// Full synopsis, arrow-scrollable. A full-screen invisible button holds
/// focus (the player's remote-catcher pattern): up/down scroll by a step,
/// Select or Back closes.
private struct DescriptionOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let text: String
    let onClose: () -> Void

    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var maxOffset: CGFloat { max(contentHeight - viewportHeight, 0) }

    var body: some View {
        ZStack {
            ATVBackground()

            VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                Text(title)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                GeometryReader { viewport in
                    Text(text)
                        .font(.system(size: 28))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { geo in
                                Color.clear.onAppear { contentHeight = geo.size.height }
                            }
                        )
                        .offset(y: -offset)
                        .onAppear { viewportHeight = viewport.size.height }
                }
                .clipped()

                Text(maxOffset > 0 ? "Swipe up/down to scroll · press Back to close"
                                   : "Press Back to close")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(.horizontal, 220)
            .padding(.vertical, 90)

            // Invisible focus holder: Select closes, moves scroll.
            Button(action: onClose) { Color.clear }
                .buttonStyle(PlainCardButtonStyle())
        }
        .onMoveCommand { direction in
            let step: CGFloat = 340
            withAnimation(.easeOut(duration: 0.25)) {
                switch direction {
                case .down: offset = min(offset + step, maxOffset)
                case .up: offset = max(offset - step, 0)
                default: break
                }
            }
        }
        .onExitCommand { onClose() }
        .onPlayPauseCommand { onClose() }
    }
}

/// A 1–10 Trakt-style rating picker: a row of ten number buttons plus Clear.
/// tvOS-focusable, dismisses on selection.
private struct RatingPickerOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let current: Int?
    let onRate: (Int?) -> Void
    let onCancel: () -> Void
    @FocusState private var focus: Int?

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
                .onTapGesture { onCancel() }
            VStack(spacing: OrivioSpacing.xl) {
                Text("Rate")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(title)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)

                HStack(spacing: OrivioSpacing.md) {
                    ForEach(1...10, id: \.self) { n in
                        Button { onRate(n) } label: {
                            Text("\(n)")
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundStyle(current == n ? theme.palette.onSecondary : theme.palette.textPrimary)
                                .frame(width: 74, height: 90)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(current == n ? theme.palette.secondary : theme.palette.backgroundElevated)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(focus == n ? theme.palette.secondary : .clear, lineWidth: 4)
                                )
                                .focusLift(OrivioFocus.control, focus == n)
                        }
                        .buttonStyle(.plain)
                        .focused($focus, equals: n)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: focus)

                if current != nil {
                    Button { onRate(nil) } label: {
                        Text("Clear rating")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(OrivioPrimitives.error)
                            .padding(.horizontal, 28).padding(.vertical, 12)
                            .background(Capsule().fill(theme.palette.backgroundElevated))
                            .overlay(Capsule().strokeBorder(focus == 0 ? OrivioPrimitives.error : .clear, lineWidth: 4))
                    }
                    .buttonStyle(.plain)
                    .focused($focus, equals: 0)
                }

                Text("Press Menu to cancel")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(OrivioSpacing.huge)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(theme.palette.background)
            )
        }
        .onExitCommand { onCancel() }
        .onAppear { focus = current ?? 8 }
    }
}

/// Like the app's FlatCardButtonStyle, but the focus lift waits until the
/// row has slid the card into the first column.
struct DelayedLiftCardButtonStyle: ButtonStyle {
    var delay: Duration = episodeLiftDelay   // match the scroll animation

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, delay: delay)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let delay: Duration
        @State private var lifted = false

        var body: some View {
            configuration.label
                .focusLift(OrivioFocus.card, lifted, animation: episodeLiftAnimation)
                .cardPressDip(configuration.isPressed)
                // Restarts on every focus change; a newer change cancels
                // the pending lift, so fast presses never lift mid-slide.
                .task(id: isFocused) {
                    guard isFocused else { lifted = false; return }
                    try? await Task.sleep(for: delay)
                    if !Task.isCancelled { lifted = true }
                }
        }
    }
}

/// Section title with the page's shared left margin (Home's spotlight
/// inset) — the app-wide RowHeader uses its own, wider one.
private struct DetailRowHeader: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String

    var body: some View {
        Text(title)
            .font(FusionType.moduleHeading(theme.font))
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.leading, Spotlight.screenInset)
    }
}

/// Episode artwork; the spoiler blur is ABSENT when off (no radius-0 blur
/// layer to composite while the row slides).
private struct EpisodeArt: View {
    let url: String?
    let blurred: Bool

    var body: some View {
        if blurred {
            RemoteImage(url: url, maxDimension: Spotlight.boxWidth).blur(radius: 28)
        } else {
            RemoteImage(url: url, maxDimension: Spotlight.boxWidth)
        }
    }
}


