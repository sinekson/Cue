import SwiftUI
import AVKit

let detailButtonSize: CGFloat = 64
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

/// Details' depth below the billboard (see `DetailView.rowsDepth`).
@Observable @MainActor
final class DetailRowsDepth {
    var depth = 0
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
    @ViewBuilder let content: (FocusState<Value?>.Binding) -> Content
    @FocusState private var focus: Value?

    var body: some View {
        content($focus)
            .defaultFocus($focus, defaultValue)
            .onChange(of: focus) { _, new in if bridge.current != new { bridge.current = new } }
            .onChange(of: bridge.requested?.id) { _, _ in focus = bridge.requested?.value }
    }
}

/// Reads the depth for its content alone: only it updates on a change.
private struct RowsDepthReader<Content: View>: View {
    let model: DetailRowsDepth
    @ViewBuilder let content: (Int) -> Content
    var body: some View { content(model.depth) }
}

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
            airCache.removeAll()
        }
    }

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
    @Published var trailers: [TMDBService.Trailer] = []
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

        // The one episode list (the add-on's, else TMDB's).
        let full = await SeriesEpisodes.fullMeta(for: canonical, addonManager: addonManager)
        // Opened through the swap: the page stays as it is until it's over.
        if let wait = settleUntil?.timeIntervalSinceNow, wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
        meta = full
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
        isLoading = false

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
            await self.apply(detail: await enrichTask?.value ?? nil, tmdb: tmdb)
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
        if tmdb.useDetails { about = detail.about }
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
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var layout: HomeCatalogSettingsStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @StateObject private var viewModel: DetailViewModel

    /// Play: finds the first source IN PLACE (the button says so — see
    /// `PlayLauncher`) and the player opens.
    @ObservedObject private var launcher = PlayLauncher.shared

    private func play(_ video: MetaVideo?, fromStart: Bool = false, onButton: Bool = false) {
        launcher.play(viewModel.meta, video, fromStart: fromStart, overlay: !onButton)
    }

    /// Hold Play (or an episode's "Choose Source"): the source picker, over
    /// the app (`SourcePicker`).
    private func openSources(_ video: MetaVideo?) {
        SourcePicker.shared.open(viewModel.meta, video)
    }
    var onSelectItem: (MetaItem) -> Void = { _ in }
    var onSelectPerson: (Int, String) -> Void = { _, _ in }
    var onSelectCompany: (TMDBService.Company) -> Void = { _ in }
    @State private var activeTrailer: TMDBService.Trailer?
    /// The series' size and status, once loaded (see `FixedFocusShowInfo`).
    @State private var showInfo: TMDBService.ShowSize?
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
    /// The button row as DRAWN: the one that is a pill (the focused one —
    /// or, focus elsewhere, the last focused), and whether it's focused
    /// (white). Both follow focus after `DetailActionButton.paintDelay`, so
    /// a one-frame visit (a vertical move lands on a circle before the
    /// row's redirect puts focus on Play) never paints.
    @State private var pillAction: ActionControl = .play
    /// (From the billboard: Play lit from the first frame — the swap brought
    /// it in lit; focus lands on it a moment later without a visible change.)
    @State private var litAction: ActionControl? = MainActor.assumeIsolated {
        ModeSwap.shared.billboardItemID != nil && !ModeSwap.shared.arrivedFromBox ? .play : nil
    }
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
    /// Play's label as the billboard knew it (see `ModeSwap`).
    @State private var handedPlayTitle: String? = MainActor.assumeIsolated {
        ModeSwap.shared.billboardItemID != nil ? ModeSwap.shared.billboardPlayTitle : nil
    }
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
    /// The season selector above the box has focus.
    @FocusState private var seasonFocused: Bool
    /// The season names' widths (at full size), for the selector's layout.
    @State private var seasonWidths: [Int: CGFloat] = [:]
    /// Which way the season names last moved (for their slide).
    @State private var seasonStep = 1
    /// Focus is in the episode row.
    @State private var episodeRowFocused = false
    /// A new value moves focus into the episode row (see `EpisodeRow`).
    @State private var episodeFocusRequest = 0
    /// How Play was pressed while a series' episode list was still loading —
    /// replayed against the real episode the moment it resolves.
    private enum PendingPlay { case auto, manual }
    @State private var pendingSeriesPlay: PendingPlay?
    /// Down pressed on the buttons before a show's episodes were in: into the
    /// row the moment they are (not dropped, and not on to the rows below).
    @State private var pendingEpisodesDown = false

    /// A show still loading its episodes: nothing below the buttons yet.
    private var episodesPending: Bool {
        viewModel.meta.isSeries && rowEpisodes.isEmpty && viewModel.isLoading
    }
    /// The rows below the episodes (More Like This, Cast, About) are built a
    /// moment after the page's content is in — not in the swap's last frames,
    /// where building all their cards at once made it stutter.
    @State private var moreReady = false
    /// …a film's Down before then: into the first of them once they are.
    @State private var pendingMoreDown = false
    /// Programmatic focus into a More row (its count goes up).
    @State private var moreFocusRequests: [MoreRow: Int] = [:]
    private var morePending: Bool { !viewModel.meta.isSeries && !moreReady }
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
        onSelectItem: @escaping (MetaItem) -> Void = { _ in },
        onSelectPerson: @escaping (Int, String) -> Void = { _, _ in },
        onSelectCompany: @escaping (TMDBService.Company) -> Void = { _ in },
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
        _depth = State(initialValue: fromBox ? ModeSwap.boxDepthHandover : 1)
        _billboardSeriesSize = State(initialValue: fromBillboard
            ? MainActor.assumeIsolated { ModeSwap.shared.billboardSeriesSize } : nil)
        // (From the billboard its buttons are already in: Home brought them
        // in with the swap. Only from a box they still come in here.)
        _swappedIn = State(initialValue: !fromBillboard || !fromBox)

        self.onReturnToBillboard = onReturnToBillboard
        self.onSelectItem = onSelectItem
        self.onSelectPerson = onSelectPerson
        self.onSelectCompany = onSelectCompany
    }

    var body: some View {
        ZStack {
            ATVBackground()
            if RenderProbe.shared.flags.detailsOnRows {
                rowsLayer
            } else {
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
                                    // Scrolled above the More row in view: out
                                    // of sight (it peeked over the row's title).
                                    .opacity(page == .more ? 0 : 1)
                                    .animation(detailPageScroll, value: page == .more)
                            }
                            if morePageTitle != nil, moreReady {
                                morePage(height: geo.size.height)
                                    .id(DetailPage.more)
                                    // (Not before the episodes above them: a
                                    // Down then waits for those instead.)
                                    .disabled(episodesPending)
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
                        // More scrolls by its rows (`moreRow`), each to one spot.
                        guard newPage != .more else { return }
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
            .opacity(trailerFullscreen ? 0 : 1)
            // Hidden is NOT unfocusable: without this, focus could stay on the
            // invisible synopsis during full-screen — whose move-handler then
            // swallowed every press, locking full-screen mode in.
            .disabled(trailerFullscreen || aboutExpanded)
            }

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

            // About's description, whole.
            if aboutExpanded, let text = viewModel.meta.description {
                DetailAboutFull(title: viewModel.meta.name, text: text) { aboutExpanded = false }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: aboutExpanded)
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
                  activeTrailer == nil,
                  teaserFocused, actionFocus == nil else { return }
            // A real rest, not a reading pause: the first press after the
            // chrome fades only brings it back, so this must never fire while
            // someone is still deciding.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, backdropTrailerPlaying, !trailerFullscreen,
                  !fullscreenCooldown, activeTrailer == nil,
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
            // Dev: -detailRows scrolls to the rows below the overview (the
            // simulator can't press Down).
            if ProcessInfo.processInfo.arguments.contains("-detailRows") {
                try? await Task.sleep(for: .seconds(4))
                if viewModel.meta.isSeries { page = .episodes } else { focusMoreRow(moreRows.first ?? .about) }
                if ProcessInfo.processInfo.arguments.contains("-detailAbout") {
                    try? await Task.sleep(for: .seconds(1))
                    focusMoreRow(.about)
                }
            }
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
                    NSLog("[CueFocus] focused=%@ fs=%d captureFocus=%d teaser=%d action=%@",
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
        // The More rows: shortly after the content is in (or at once when the
        // viewer heads down there).
        .task(id: viewModel.isLoading) {
            guard !viewModel.isLoading, !moreReady else { return }
            try? await Task.sleep(for: .milliseconds(350))
            moreReady = true
        }
        .onChange(of: page) { _, newPage in
            if newPage != .overview { moreReady = true }
        }
        .onChange(of: moreReady) { _, ready in
            guard ready, pendingMoreDown, let first = moreRows.first else { return }
            pendingMoreDown = false
            DispatchQueue.main.async { moreFocusRequests[first, default: 0] += 1 }
        }
        .onChange(of: rowEpisodes.isEmpty) { _, empty in
            guard !empty, pendingEpisodesDown else { return }
            pendingEpisodesDown = false
            if actionFocus != nil { enterEpisodeRow() }
        }
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
            case .auto: play(target, onButton: true)
            case .manual: openSources(target)
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
        .task {
            // Opened from the billboard: let the swap play first — the load
            // re-renders the whole page as its data lands, and doing that
            // mid-animation dropped frames.
            // (Fetching starts at once; the page only changes once it's over.)
            await viewModel.load(addonManager: addonManager, mdbSettings: mdblist.settings, tmdb: tmdbSettings.settings,
                                 settleUntil: fromBillboard
                                    ? Date().addingTimeInterval(ModeSwap.swapSettle + 0.15) : nil)
        }
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
            // Home has played the whole swap (the picture closer, the bar
            // away, the hint changed, the buttons in) and this page took
            // over looking exactly like that.
            if fromBox {
                withAnimation(ModeSwap.buttonsIn) {
                    swappedIn = true
                    scrim = 1
                }
            }
            // A press made while Home handed over: it's this page's.
            if let held = ModeSwap.shared.heldPress {
                ModeSwap.shared.heldPress = nil
                DispatchQueue.main.async { act(held) }
            }
        }
        // Back, when opened from the billboard: from a lower page first up
        // to the overview; from the overview, this page's half of the swap
        // out, then Home plays the rest.
        // (In trailer mode Back first only brings the page back.)
        .onExitCommand(perform: launcher.searching != nil ? { launcher.cancel() }
                       : trailerMode ? { revealTrailerPage() }
                       : fromBillboard && onReturnToBillboard != nil ? { backToBillboard() } : nil)
        // Trailer mode starts only while Play HOLDS focus: moving off it
        // (right to the other buttons, down to Episodes) stops the trailer;
        // back on Play the countdown starts over.
        .onChange(of: actionFocus) { old, new in
            // Moved on (between buttons) after an early Down: that Down is
            // void. (Focus first landing on Play isn't a move.)
            if old != nil { pendingEpisodesDown = false; pendingMoreDown = false }
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
    }

    /// Behind the whole page, pinned: the calm ground of Home's rows (the
    /// title's colours). The picture scrolls away over it with the overview
    /// (`stagePicture`), and Episodes / More sit on it.
    private var backdrop: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                TitleTintBackground(tint: tint, second: tintSecond)
                    .task(id: viewModel.meta.id) {
                        guard let url = viewModel.meta.background ?? viewModel.meta.poster,
                              let colors = await FixedFocusTint.colors(for: url, flags: RenderProbe.shared.flags)
                        else { return }
                        tint = colors.first
                        tintSecond = colors.second
                    }
                // For now the picture stays behind every page (Episodes and
                // More too, with the same left fade); how it hands over to
                // the colours below the overview is still open (its edge,
                // below the screen here, is for that).
                stagePicture(size: geo.size)
                // Episodes / More: the picture steps back (Render Lab →
                // Details: picture dim below), so the cards on the right —
                // outside the left fade — sit on calm ground.
                Color.black
                    .opacity(page == .overview ? 0 : RenderProbe.shared.flags.detailsPictureDim)
                    .animation(detailPageScroll, value: page == .overview)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    /// THE PICTURE — part of the overview page, so it scrolls away with it
    /// (one long page, no fades): the backdrop (or its trailer) under the
    /// billboard's shade, exactly as on Home's billboard, and below the
    /// screen its EDGE (Render Lab → Details: picture edge) — the picture's
    /// own bottom, mirrored, blurred and faded into the colours (it seems to
    /// melt as it scrolls up), or a plain edge with a soft shadow.
    private func stagePicture(size: CGSize) -> some View {
        let url = viewModel.meta.background ?? viewModel.meta.poster
        let drift = StagePictureView.drift
        return ZStack {
            // Decorative backdrop — kept out of hit testing so it cannot
            // swallow the action row's context-menu hit test (the same bug
            // the home Featured bar caused for Continue Watching).
            // EXACTLY Home's billboard picture (`StagePictureView`): the same
            // image (so it's in memory already: no blink on the swap), the
            // same size — a little wider than the screen — and place.
            RemoteImage(url: url, maxDimension: StagePictureView.pictureSize.width)
                .allowsHitTesting(false)
                .frame(width: size.width + 2 * drift, height: size.height)
                .frame(width: size.width, height: size.height)
                // Opened from the billboard: the picture steps a little closer
                // — the sign a page has opened (`ModeSwap.stepIn`).
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
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                .opacity(showBackdropTrailer ? 1 : 0)
            // Episodes / More: the same picture, blurred (made once, a
            // still — Render Lab → Details: picture blur below), fading
            // in over the sharp one as you leave the overview.
            ZStack {
                if let blurredBackdrop {
                    Image(uiImage: blurredBackdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width + 2 * drift, height: size.height)
                        .frame(width: size.width, height: size.height)
                        // As close as the sharp picture (the step-in zoom).
                        .scaleEffect(ModeSwap.depthScale(depth))
                }
            }
            .opacity(page == .overview ? 0 : 1)
            .animation(detailPageScroll, value: page == .overview)
            .task(id: "\(viewModel.meta.id)|\(RenderProbe.shared.flags.detailsPictureBlur)") {
                blurredBackdrop = await BlurredBackdrop.image(
                    for: url, strength: RenderProbe.shared.flags.detailsPictureBlur)
            }
            // The stage's shade — the billboard's, exactly (left fade,
            // vignette).
            BillboardShade()
                .opacity(trailerFullscreen ? 0 : trailerMode ? TrailerMode.scrimOpacity : scrim)
                .animation(TrailerMode.fade, value: trailerMode)
                // Episodes / More: lighter — the blur and the dim already
                // darken (Render Lab → Left fade: Episodes).
                .opacity(page != .overview ? RenderProbe.shared.flags.episodesLeftFade : 1)
                .animation(detailPageScroll, value: page == .overview)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        // The overview: faded out at the bottom into the colours, as the
        // billboard (Render Lab → Billboard bottom fade); below it, full.
        .mask {
            let fade = page == .overview ? RenderProbe.shared.flags.billboardBottomFade : 0
            let start = max(size.height - fade, 0) / size.height
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: start),
                                   .init(color: .black.opacity(fade > 0 ? 0 : 1), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .animation(detailPageScroll, value: page == .overview)
        }
        .allowsHitTesting(false)
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
            NSLog("[CueTrailer] backdrop resolve failed for %@", candidates.joined(separator: ","))
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
            NSLog("[CueTrailer] backdrop %@ failed to load: %@", resolvedKey,
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
                        // (In place: it crossfades with the billboard's.)
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
    // MARK: - Details on Home's rows (Render Lab → Details: rows)

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
                           active: true, billboardStepIn: false, progress: [:],
                           // Episodes: landscape tiles (the collections' size —
                           // about 3½ in view), moving focus.
                           landscapeRowIDs: seasonIDs,
                           destinationRowIDs: seasonIDs,
                           onSelect: onSelectItem,
                           onSelectFeatured: { _ in },
                           onResume: { _ in },
                           titleMenu: { item, rowID in
                               rowID.hasPrefix(Self.seasonRowPrefix)
                                   ? (rowEpisodes.firstIndex { $0.id == item.id }.flatMap { episodeMenu($0)?.entries } ?? [])
                                   : TitleMenu.shared.entries(for: item)
                           },
                           onDepth: { rowsDepth.depth = $0 },
                           externalBillboard: true,
                           cardStates: episodeCardStates,
                           onSelectInRow: { item, rowID in
                               guard rowID.hasPrefix(Self.seasonRowPrefix) else { return false }
                               if let episode = rowEpisodes.first(where: { $0.id == item.id }) { play(episode) }
                               return true
                           },
                           command: rowCommand,
                           rigidRest: Self.rowsRestY,
                           rigidNameY: Self.rowsNameY,
                           hidesBillboardPicture: true,
                           // The row's name is the season control: Up from the
                           // episodes, Left / Right step the seasons.
                           titleControlRowIDs: hasSeasonControl ? seasonIDs : [],
                           titleArrows: seasonArrows,
                           onTitleMove: { _, step in stepSeason(by: step) },
                           onTitleFocus: { _, focused in seasonNameFocused = focused },
                           // The season's progress: on its own line under the
                           // row's name.
                           rowTitleAccessories: rowProgressAccessory,
                           // The billboard's text and buttons: the engine's,
                           // moved with the rows in the same animation.
                           billboardOverlay: rowsBillboardOverlay,
                           billboardOverlayHeight: Self.overlayHeight) { item, position in
                // Up into the billboard lands on its invisible card: on to
                // Play (the billboard's focus is its buttons).
                if position != nil { DispatchQueue.main.async { actionFocus = .play } }
                // The episode in focus (the progress map follows it).
                if item.type == "episode" { focusedRowEpisode = item.id }
            }
            .ignoresSafeArea()
            .task(id: viewModel.meta.id) {
                // Every season's stills, lengths, air dates.
                for season in viewModel.meta.seasons { await viewModel.loadSeason(season) }
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
    /// The episode row's name (the season control) has focus.
    @State private var seasonNameFocused = false

    /// Under the billboard the first row waits as far down as the scroll
    /// that leaves only the buttons on screen above it (the screen's edge
    /// halfway between the badges and them — `buttonsTopGap`) brings it to
    /// Home's spot. Its cards' top bit is then on the screen, cut off by a
    /// line there (`concealTravel`); one plain scroll brings it up. Only its
    /// NAME shows on the billboard — Home's next-row look, smaller, ⌄ after
    /// it, dimmed — lifted above its cards to `rowsNameY`; the lift shrinks
    /// to nothing on the way, so name and cards meet.
    private static var rowsRestY: CGFloat {
        FixedFocusMetrics.rowTop + FixedFocusBillboardText.buttonsY - buttonsTopGap
    }
    /// The badges end ~29 pt above the buttons: the edge halfway.
    private static let buttonsTopGap: CGFloat = 15
    private static let rowsNameY: CGFloat = 1080 - 60 - FixedFocusMetrics.titleHeight


    /// THE PICTURE stays: sharp under the overview (the billboard's shade
    /// on it); below it, its blurred copy fades in over it and it steps
    /// back (Render Lab → Details: picture blur / dim below), the shade
    /// lighter — the rows sit on calm ground of the same picture.
    private var rowsBackdrop: some View {
        RowsDepthReader(model: rowsDepth) { depth in rowsBackdrop(below: depth > 0) }
    }

    private func rowsBackdrop(below: Bool) -> some View {
        let url = viewModel.meta.background ?? viewModel.meta.poster
        let drift = StagePictureView.drift
        let flags = RenderProbe.shared.flags
        return ZStack {
            TitleTintBackground(tint: tint, second: tintSecond)
                .task(id: viewModel.meta.id) {
                    guard let url, let colors = await FixedFocusTint.colors(for: url, flags: flags)
                    else { return }
                    tint = colors.first
                    tintSecond = colors.second
                }
            // EXACTLY where Home's billboard left it (the swap): its size, a
            // little wider than the screen, leaned in by the step-in zoom.
            ZStack {
                RemoteImage(url: url, maxDimension: StagePictureView.pictureSize.width)
                    .frame(width: 1920 + 2 * drift, height: 1080)
                ZStack {
                    if let blurredBackdrop {
                        Image(uiImage: blurredBackdrop)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 1920 + 2 * drift, height: 1080)
                    }
                }
                .opacity(below ? 1 : 0)
            }
            .scaleEffect(ModeSwap.depthScale(depth))
            .frame(width: 1920, height: 1080)
            .clipped()
            Color.black.opacity(below ? flags.detailsPictureDim : 0)
            // The billboard's shade (from a box: finishing its handover).
            BillboardShade()
                .opacity(below ? flags.episodesLeftFade : scrim)
        }
        .frame(width: 1920, height: 1080)
        // (On the backdrop itself: an empty view never starts a task. By the
        // picture's address: it arrives after the page opens.)
        .task(id: "\(url ?? "")|\(flags.detailsPictureBlur)") {
            blurredBackdrop = await BlurredBackdrop.image(for: url, strength: flags.detailsPictureBlur)
        }
        .animation(detailPageScroll, value: below)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Where you are in the season, under the row's name (it's about the
    /// season): its ticks, then "3 of 7".
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

    /// Which of the season control's arrows show.
    private var seasonArrows: [String: FixedFocusTitleArrows] {
        let seasons = rowSeasons
        guard let index = rowSeason.flatMap({ seasons.firstIndex(of: $0) }) else { return [:] }
        return [Self.episodesRowID: FixedFocusTitleArrows(previous: index > 0, next: index < seasons.count - 1)]
    }

    /// Left / Right on the season control: the season before / after.
    private func stepSeason(by step: Int) {
        let seasons = rowSeasons
        guard let index = rowSeason.flatMap({ seasons.firstIndex(of: $0) }),
              seasons.indices.contains(index + step) else { return }
        stepSeason(to: seasons[index + step])
    }

    private static let episodesRowID = seasonRowPrefix + "all"

    /// The episodes row: every season in the pill's order (Specials last).
    private var rowItemsInOrder: [EpisodeRowItem] {
        let order = Dictionary(rowSeasons.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return episodeRowItems.enumerated().sorted {
            (order[$0.element.season] ?? .max, $0.offset) < (order[$1.element.season] ?? .max, $1.offset)
        }.map(\.element)
    }

    /// The season the row is in: its focused episode's, else the aimed one's.
    private var rowSeason: Int? {
        let items = rowItemsInOrder
        let id = focusedRowEpisode ?? aimedRowEpisode
        // (Not yet aimed: Play's season — the row opens there; "Season 1"
        // first would flash.)
        return items.first { $0.id == id }?.season ?? seriesPlayTarget?.season ?? rowSeasons.first
    }

    /// Before the episode list is in (held until the swap from Home has
    /// played): the season Play starts, as the billboard knew it ("Play
    /// S4:E19") — the row's name is there from the first frame.
    private var provisionalSeasonTitle: String {
        if let title = handedPlayTitle,
           let match = title.firstMatch(of: /S(\d+):E\d+/), let season = Int(match.1) {
            return seasonName(season)
        }
        return "Episodes"
    }

    /// Changes when the row (or Play's episode) does: re-aim.
    private var aimKey: String { "\(rowItemsInOrder.count)-\(seriesPlayTarget?.id ?? "")" }

    private func aimRow(at episodeID: String) {
        guard let index = rowItemsInOrder.firstIndex(where: { $0.id == episodeID }) else { return }
        aimedRowEpisode = episodeID
        rowCommand = FixedFocusRowsCommand(action: .aim(rowID: Self.episodesRowID, index: index))
    }

    /// A season's way in: its first episode not watched, else its first.
    private func entryEpisode(season: Int) -> EpisodeRowItem? {
        let episodes = rowItemsInOrder.filter { $0.season == season }
        return episodes.first { !$0.state.watched } ?? episodes.first
    }

    /// The seasons, then Specials.
    private var rowSeasons: [Int] {
        viewModel.meta.seasons.sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
    }

    /// The map's episode: the one in focus, else where the season starts.
    private var rowProgressEpisode: MetaVideo? {
        let id = focusedRowEpisode ?? aimedRowEpisode
        return rowEpisodes.first { $0.id == id } ?? rowEpisodes.first { $0.season == rowSeason }
    }

    /// More than one season: the row's name is the season control.
    private var hasSeasonControl: Bool { rowSeasons.count > 1 }

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
            .environmentObject(theme).environmentObject(addonManager)
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
            FixedFocusBillboardText(item: viewModel.meta, info: showInfo, ratings: ratingsBadges)
                .task(id: viewModel.meta.id) { showInfo = await FixedFocusShowInfo.load(viewModel.meta) }
                .padding(.leading, FixedFocusMetrics.titleInset)
                .padding(.top, FixedFocusBillboardText.topY)
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
            // ONE row: every episode (the season pill above it jumps).
            let episodes = rowItemsInOrder
            if episodes.isEmpty {
                // Its name at once; its cards when the list is in.
                rows.append(HomeRow(id: Self.episodesRowID, title: provisionalSeasonTitle, items: []))
            } else {
                rows.append(HomeRow(
                    id: Self.episodesRowID, title: rowSeason.map(seasonName) ?? "Episodes",
                    items: episodes.map { MetaItem(id: $0.id, type: "episode", name: $0.title, background: $0.image) },
                    subtitles: Dictionary(episodes.map { ($0.id, $0.facts) }, uniquingKeysWith: { a, _ in a })))
            }
        }
        if !viewModel.moreLikeThis.isEmpty {
            rows.append(HomeRow(id: "detail.more", title: "More Like This", items: viewModel.moreLikeThis))
        }
        if let collection = viewModel.collection, !viewModel.collectionParts.isEmpty {
            rows.append(HomeRow(id: "detail.collection", title: collection.name, items: viewModel.collectionParts))
        }
        return rows
    }

    /// Each episode's state line on its card (Continue Watching's).
    private var episodeCardStates: [String: FixedFocusCardState] {
        Dictionary(episodeRowItems.map { item in
            (item.id, FixedFocusCardState(label: item.state.label, fraction: item.state.progress,
                                          right: item.state.remaining.map { "\($0) left" } ?? item.state.status))
        }, uniquingKeysWith: { a, _ in a })
    }

    private func overviewPage(size: CGSize) -> some View {
        let height = size.height
        // The title block (`TitleBlock`): every part at a fixed spot, the
        // buttons in its button row. (The billboard is laid out the same.)
        return ZStack(alignment: .topLeading) {
            // THE BILLBOARD'S TEXT, exactly (same view, same place): logo,
            // summary, name, facts, the status badge and ratings chips.
            FixedFocusBillboardText(item: viewModel.meta, info: showInfo, ratings: ratingsBadges)
                // The season count and the status chip (AIRING / RETURNING /
                // ENDED), as on Home — re-drawn once they're known.
                .task(id: viewModel.meta.id) { showInfo = await FixedFocusShowInfo.load(viewModel.meta) }
                // Steps aside while a trailer has the screen.
                .opacity(trailerMode ? 0 : 1)
                .animation(TrailerMode.fade, value: trailerMode)
                // From a box: fades in with the buttons (it wasn't there).
                .opacity(fromBox && !swappedIn ? 0 : 1)
                .padding(.leading, FixedFocusMetrics.titleInset)
                .padding(.top, FixedFocusBillboardText.topY)
            headerExtras
                // Each button grows out of a dot (`DotGrow`, per button).
                .frame(height: TitleBlock.buttonHeight)
                .padding(.top, FixedFocusBillboardText.buttonsY)
        }
        .frame(height: height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            hint(viewModel.meta.isSeries ? "Episodes" : morePageTitle,
                 up: false, on: .overview, y: TitleBlock.hintY(screenHeight: height),
                 // Comes down into place from a little above (Home's went
                 // down off the screen) — see `ModeSwap`.
                 // (From the billboard it's there from the start: Home
                 // already crossfaded to it.)
                 swapOut: fromBox && !swappedIn)
        }
    }

    /// Episodes: seasons + the episode row — the first of the rows below
    /// the overview (More's follow right under it, no page break).
    private func episodesPage(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // No big "Episodes" title — the "▴ Overview" hint above and the
            // season selector say where you are.
            episodesSection(width: size.width)
        }
        // The box exactly where Home's box is (the season selector above it).
        .padding(.top, FixedFocusMetrics.boxFrame.minY
                 - (hasSeasonSelector ? Self.selectorHeight + Self.selectorGap : 0))
        .overlay(alignment: .topLeading) {
            hint("Overview", up: true, on: .episodes, y: TitleBlock.topHintY)
        }
    }

    /// More: every remaining section; each row, when focused, scrolls to
    /// the spot below the hint (`moreRowTop`).
    private func morePage(height: CGFloat) -> some View {
        // What you most likely want next first: something similar, the
        // rest of the collection, then who made it, then the footers.
        VStack(alignment: .leading, spacing: CueSpacing.xxl) {
            // By position: identified by the row itself, each section would
            // share its id with its scroll anchor (`MoreRowAnchor`), and
            // `scrollTo` took the section — its title at the screen's top.
            ForEach(Array(moreRows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .collection: collectionSection
                case .moreLikeThis: moreLikeThisSection
                case .cast: castSection
                case .about: aboutSection
                }
            }
        }
        // Under the episode row (a show) — or, a film, a screen down.
        .padding(.top, viewModel.meta.isSeries ? CueSpacing.xxl : Self.moreRowTop)
        // Room below the last row, so every row — the last one too — can
        // scroll up to the same spot. (A short More page couldn't scroll at
        // all, and the rows' scrolls fought the page's end.)
        .padding(.bottom, height - Self.moreRowTop)
        .frame(minHeight: height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            // Only on the first row: Up goes there (deeper, to the row above).
            hint(viewModel.meta.isSeries ? "Episodes" : "Overview",
                 up: true, on: .more, y: TitleBlock.topHintY)
                .opacity(moreRow == moreRows.first ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: moreRow)
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

    /// The rows below the overview (after a show's episodes), those with
    /// something in them: what you most likely want next first — the rest
    /// of the collection, something similar — then who made it, then About.
    private var moreRows: [MoreRow] {
        var rows: [MoreRow] = []
        if viewModel.collection != nil, !viewModel.collectionParts.isEmpty { rows.append(.collection) }
        if !viewModel.moreLikeThis.isEmpty { rows.append(.moreLikeThis) }
        if !(viewModel.crew + viewModel.cast).isEmpty { rows.append(.cast) }
        rows.append(.about)
        return rows
    }

    /// The first More row's name — what the hint above it points at, so a
    /// hint never names something that isn't there. Nil: no More rows.
    private var morePageTitle: String? {
        switch moreRows.first {
        case .collection: return viewModel.collection?.name
        case .moreLikeThis: return "More Like This"
        case .cast: return "Cast & Crew"
        case .about: return "About"
        case nil: return nil
        }
    }

    /// Down from the buttons: land on an episode — the one last focused in
    /// the row, else the Play target (if it's in the shown season), else
    /// the season's first. Scroll it into place first so its cell exists.
    private func enterEpisodeRow() {
        guard !rowEpisodes.isEmpty else { return }
        // Deferred one turn: the engine's own move onto the chip must finish
        // before a programmatic focus change can win.
        episodeFocusRequest += 1
    }

    /// Everything on the overview below the shared title block: just the
    /// buttons (the rest is in `aboutSection`, on the More page).
    private var headerExtras: some View {
        // The row with its own focus state (see `actionFocus`); Play is the
        // default.
        FocusBridgeHost(bridge: actionBridge, defaultValue: .play) { focus in actionRow(focus) }
            // (The text's left edge — the billboard's column.)
            .padding(.leading, FixedFocusMetrics.titleInset)
            // Down before the episodes are in: held, not lost.
            .onMoveCommand { direction in
                guard direction == .down else { return }
                if episodesPending { pendingEpisodesDown = true }
                else if morePending { pendingMoreDown = true }
            }
    }


    /// A Select, Back or Down made during the swap (`ModeSwap.heldPress`).
    private func act(_ held: ModeSwap.HeldPress) {
        switch held {
        case .play:
            let target = viewModel.meta.isSeries ? seriesPlayTarget : nil
            if viewModel.meta.isSeries, target == nil { pendingSeriesPlay = .auto }
            else { play(target, onButton: true) }
        case .back:
            backToBillboard()
        case .down:
            if episodesPending { pendingEpisodesDown = true }
            else if !rowEpisodes.isEmpty { enterEpisodeRow() }
        }
    }

    private func backToBillboard() {
        guard page == .overview else {
            actionFocus = .play
            return
        }
        guard swappedIn else { return }
        // Home — left exactly as this page looks, buttons included — is back
        // at once and plays the swap the other way, all together.
        guard fromBox else { onReturnToBillboard?(); return }
        withAnimation(ModeSwap.buttonsOut) { swappedIn = false }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.14))
            onReturnToBillboard?()
        }
    }

    /// The title block's ratings row (nil = none).
    private var ratingsBadges: AnyView? {
        FixedFocusBillboardText.ratingsChips(viewModel.mdbRatings, settings: mdblist.settings,
                                             item: viewModel.meta)
    }

    /// Play/Resume (+ Start Over) + circular add / watched / rate / trailer.
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
                let finding = launcher.searching == PlayLauncher.key(viewModel.meta, target)
                DetailActionButton(
                    icon: "play.fill", title: finding ? "Finding a source…" : playTitle(target),
                    isPrimary: true, lit: litAction == .play, busy: finding,
                    action: {
                        if viewModel.meta.isSeries, target == nil { pendingSeriesPlay = .auto }
                        else { play(target, onButton: true) }
                    },
                    // Hold Select: straight to the source list.
                    onHold: {
                        if viewModel.meta.isSeries, target == nil { pendingSeriesPlay = .manual }
                        else { openSources(target) }
                    }
                )
                .focused(focus, equals: .play)
                .modifier(DotGrow(shown: swappedIn, index: 0))
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
                HStack(spacing: CueSpacing.md) {
                    let saved = library.contains(viewModel.meta)
                    DetailActionButton(
                        icon: saved ? "checkmark" : "plus",
                        title: saved ? "In Library" : "Add to Library",
                        isPrimary: false, lit: litAction == .library,
                        // No toast: the button itself says it ("In Library").
                        action: { library.toggle(viewModel.meta) }
                    )
                    .focused(focus, equals: .library)
                    .modifier(DotGrow(shown: swappedIn, index: 1))
                    // Always there (the row never changes shape): without a
                    // trailer it says so.
                    DetailActionButton(
                        icon: "play.rectangle.fill", title: "Watch Trailer",
                        isPrimary: false, lit: litAction == .trailer,
                        action: {
                            if let trailer = viewModel.trailers.first { activeTrailer = trailer }
                            else { ToastCenter.shared.show("No trailer for this title", icon: "film") }
                        }
                    )
                    .focused(focus, equals: .trailer)
                    .modifier(DotGrow(shown: swappedIn, index: 2))
                }
                // Trailer mode: only Play stays (press it to play).
                .opacity(trailerMode ? 0 : 1)
                .animation(TrailerMode.fade, value: trailerMode)
                .focusSection()
                Spacer(minLength: 0)
            }
            .animation(DetailActionButton.open, value: litAction)
            .onChange(of: actionFocus) { _, new in
                guard let new else { litAction = nil; return }
                Task { @MainActor in
                    try? await Task.sleep(for: DetailActionButton.paintDelay)
                    guard actionFocus == new else { return }
                    pillAction = new
                    litAction = new
                }
            }
            .padding(.top, CueSpacing.xs)
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
        SeriesEpisodes.playTarget(viewModel.meta.id, in: viewModel.allEpisodesInPlayOrder,
                                  progress: progressStore, watched: watched)
    }

    /// The Play button's label on a show: just the episode ("S1:E1") — the
    /// ▶ says play; resume or not, it continues where you are.
    private func seriesPlayTitle(_ episode: MetaVideo) -> String {
        "S\(episode.season ?? 1):E\(episode.episode ?? 1)"
    }

    /// Play's title: "Play", on a show "Play S1:E1".
    private func playTitle(_ target: MetaVideo?) -> String {
        target.map { "Play \(seriesPlayTitle($0))" } ?? handedPlayTitle ?? "Play"
    }



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
        VStack(alignment: .leading, spacing: Self.selectorGap) {
            // The season selector over the box: the current season with a
            // faded preview of the ones around it. Up from the row focuses
            // it; Left/Right there jumps the row to another season.
            if hasSeasonSelector {
                seasonSelector
                    .padding(.leading, FixedFocusMetrics.titleInset)
            }

            if !rowEpisodes.isEmpty {
                // Home's Continue Watching row, exactly (`EpisodeRow`): one
                // continuous row across all seasons, the fixed box, the
                // episode's title and synopsis under it.
                EpisodeRow(episodes: episodeRowItems, index: currentIndex,
                           focusRequest: episodeFocusRequest,
                           onFocus: { i in
                               episodeIndex = i
                               syncSeasonToCurrent()
                               preloadSeasons(around: i)
                           },
                           onFocusChange: { focused in
                               episodeRowFocused = focused
                               if focused { page = .episodes }
                           },
                           onSelect: { i in
                               let list = rowEpisodes
                               if list.indices.contains(i) { play(list[i]) }
                           },
                           menu: { i in episodeMenu(i) })
                    .frame(width: width, height: EpisodeRow.height)
            } else if viewModel.isLoading {
                CueLoadingView(label: "Loading episodes")
                    .frame(height: Spotlight.rowHeight)
            }
        }
        // Where you are in the season, one tick per episode: at the top of
        // the episodes, above the seasons (it takes no room — the box stays
        // at Home's box spot).
        .overlay(alignment: .topLeading) {
            if let episode = currentEpisode {
                SeasonProgressMap(ticks: seasonTicks(for: episode),
                                  label: seasonProgressLabel(for: episode))
                    .padding(.leading, FixedFocusMetrics.titleInset)
                    // Its height (ticks, gap, label) and a gap above the seasons.
                    .offset(y: -Self.progressLift)
            }
        }
        .onChange(of: viewModel.selectedSeason) { _, newSeason in
            if let newSeason { Task { await viewModel.loadSeason(newSeason) } }
        }
    }

    /// The season progress above the seasons: its height and a gap.
    private static let progressLift: CGFloat = 12 + 12 + 26 + 22

    /// Between the season selector and the row.
    /// The season selector sits like a catalog row's name on Home: its line,
    /// then the small gap to the box.
    private static let selectorGap: CGFloat = FixedFocusMetrics.titleHeight - FixedFocusMetrics.titleLine
    private static let selectorHeight: CGFloat = FixedFocusMetrics.titleLine

    private var hasSeasonSelector: Bool { viewModel.meta.seasons.count > 1 }

    /// The row's episodes as it draws them.
    private var episodeRowItems: [EpisodeRowItem] {
        rowEpisodes.map { episode in
            let season = episode.season ?? 0
            let extra = episode.episode.flatMap { viewModel.episodeExtras[season]?[$0] }
            // TMDB's still in full resolution first: the add-on's thumbnail is
            // often small, and these cards are big.
            let image = TMDBService.originalSize(extra?.still) ?? episode.thumbnail
                ?? viewModel.meta.background ?? viewModel.meta.poster
            let progress = progressStore.progress(for: episode.id)
            let fraction = progress?.fraction ?? 0
            let done = isWatched(episode, season: season)
            let inProgress = !done && fraction > 0.02 && fraction < 0.95
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
                synopsis: episode.overview.flatMap { $0.isEmpty ? nil : $0 },
                image: image,
                state: state)
        }
    }

    /// Crossing into a season whose stills / runtimes / air dates aren't
    /// loaded yet: fetch them a few episodes ahead of the boundary.
    private func preloadSeasons(around index: Int) {
        let list = rowEpisodes
        for offset in [1, 3, -1] where list.indices.contains(index + offset) {
            if let season = list[index + offset].season { Task { await viewModel.loadSeason(season) } }
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

    private func seasonProgressLabel(for episode: MetaVideo, named: Bool = true) -> String {
        let season = episode.season ?? 0
        let all = viewModel.episodes(season: season)
        let done = all.filter { isWatched($0, season: season) }.count
        let count = "\(done) of \(all.count) watched"
        return named ? "\(seasonName(season))  •  \(count)" : count
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
        let small: CGFloat = Spotlight.headerLabelSize / Spotlight.headerTitleSize
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
                // A catalog row's name on Home: its size and weight.
                Text(seasonName(season))
                    .font(.system(size: Spotlight.headerTitleSize, weight: .semibold))
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
                    .fill(Color.white.opacity(0.4))
                    .frame(width: size, height: size)
                    .frame(width: Self.seasonDot, height: Self.seasonDot)
                    .offset(x: dotsStart + CGFloat(max(n, 0)) * (Self.seasonDot + 12))
                    .opacity(shown ? 1 : 0)
            }
        }
        .onPreferenceChange(SeasonWidthKey.self) { widths in
            seasonWidths.merge(widths) { _, new in new }
        }
        .frame(height: Self.selectorHeight)
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
            // (The episodes scroll in at once — focus never rests on
            // something off screen — and if the hand-off loses to the
            // engine, once more after the scroll.)
            guard page == .overview else { page = .episodes; return }
            page = .episodes
            enterEpisodeRow()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if seasonFocused, !episodeRowFocused { enterEpisodeRow() }
            }
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

    /// Holding Select on an episode: its menu.
    private func episodeMenu(_ index: Int) -> (title: String, entries: [MenuEntry])? {
        let list = rowEpisodes
        guard list.indices.contains(index) else { return nil }
        let episode = list[index]
        let season = episode.season ?? 0
        var entries: [MenuEntry] = []
        let fraction = progressStore.progress(for: episode.id)?.fraction ?? 0
        let started = fraction > 0.02 && fraction < 0.95
        entries.append(MenuEntry(title: started ? "Resume" : "Play", icon: "play.fill") { play(episode) })
        if started {
            entries.append(MenuEntry(title: "Play from Beginning", icon: "gobackward") {
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
            entries.append(MenuEntry(title: "Mark Previous as Watched", icon: "checklist") {
                markWatched(Array(viewModel.allEpisodesInPlayOrder[..<at]))
            })
        }
        entries.append(MenuEntry(title: season == 0 ? "Mark Specials Watched" : "Mark Season \(season) Watched",
                                 icon: "checkmark.circle.fill") { markSeasonWatched(season) })
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
        if !people.isEmpty {
            moreSection("Cast & Crew", row: .cast) {
                MoreScrollRow(items: people, pictureSize: CGSize(width: 160, height: 160), corner: 80,
                              spacing: 36, focusRequest: moreFocusRequests[.cast, default: 0],
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
        if let collection = viewModel.collection,
           !viewModel.collectionParts.isEmpty {
            moreSection(collection.name, row: .collection) {
                posterRow(viewModel.collectionParts, row: .collection)
            }
        }
    }

    // MARK: - More Like This

    @ViewBuilder
    private var moreLikeThisSection: some View {
        if !viewModel.moreLikeThis.isEmpty {
            moreSection("More Like This", row: .moreLikeThis) {
                posterRow(viewModel.moreLikeThis, row: .moreLikeThis)
            }
        }
    }

    // MARK: - About

    @State private var aboutExpanded = false

    @ViewBuilder
    private var aboutSection: some View {
        moreSection("About", row: .about) {
            DetailAbout(meta: viewModel.meta, about: viewModel.about, facts: viewModel.facts,
                        releaseDate: viewModel.releaseDate, contentRating: viewModel.contentRating,
                        language: viewModel.language, ratings: viewModel.mdbRatings,
                        settings: mdblist.settings, companies: viewModel.companies,
                        onExpand: { aboutExpanded = true },
                        onSelectCompany: { onSelectCompany($0) },
                        onFocus: { if $0 { focusMoreRow(.about) } },
                        focusRequest: moreFocusRequests[.about, default: 0])
        }
    }

    /// A More-page section: its title, then its row.
    private func moreSection<Content: View>(_ title: String, row: MoreRow,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CueSpacing.lg) {
            DetailRowHeader(title: title)
            content()
                .padding(.leading, Spotlight.screenInset)
        }
        // Scrolled above the row in view: out of sight (its foot peeked over
        // that row's title).
        .opacity(isAboveCurrent(row) ? 0 : 1)
        .animation(detailPageScroll, value: isAboveCurrent(row))
        .modifier(MoreRowAnchor(row: row, top: Self.moreRowTop))
    }

    private func isAboveCurrent(_ row: MoreRow) -> Bool {
        guard let current = moreRow, let at = moreRows.firstIndex(of: current),
              let index = moreRows.firstIndex(of: row) else { return false }
        return index < at
    }

    /// Titles as portrait posters, name and year below (Search's and
    /// Library's look).
    private func posterRow(_ items: [MetaItem], row: MoreRow) -> some View {
        MoreScrollRow(items: items, pictureSize: CGSize(width: 200, height: 300), corner: Spotlight.cornerRadius,
                      focusRequest: moreFocusRequests[row, default: 0],
                      onSelect: { onSelectItem($0) },
                      onFocus: { if $0 { focusMoreRow(row) } },
                      menu: { ($0.name, TitleMenu.shared.entries(for: $0)) }) { item, focused in
            MorePoster(item: item, focused: focused)
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
        VStack(alignment: .leading, spacing: CueSpacing.sm) {
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
            .holdMenu(focused: rawFocused) {
                var entries: [MenuEntry] = []
                if let onPlayManually {
                    entries.append(MenuEntry(title: "Play Manually", icon: "list.and.film", run: onPlayManually))
                }
                entries.append(MenuEntry(title: isWatched ? "Mark as Unwatched" : "Mark as Watched",
                                         icon: isWatched ? "eye.slash" : "checkmark.circle", run: onToggleWatched))
                return entries
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
enum MoreRow: Hashable { case collection, moreLikeThis, cast, about }

/// The scroll target of a More row: an invisible strip standing `top`
/// ABOVE the row, so scrolling it to the top puts the row's title where
/// the first row's is (below the hint) — every row lands in one place.
private struct MoreRowAnchor: ViewModifier {
    let row: MoreRow
    let top: CGFloat

    func body(content: Content) -> some View {
        // A real strip in the layout, `top` tall, ending where the row
        // starts; the pair taking no more room than the row (the negative
        // padding outside). (A background strip moved by an alignment guide
        // is laid out — and scrolled to — where the row is.)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: top)
                .id(row)
            content
        }
        .padding(.top, -top)
    }
}

/// A More row: the system's horizontal scrolling — focus moves along the
/// cards, the row follows near its edge (Search's and Library's rows, not
/// Home's fixed spot: here you scan). The focused card's picture gets the
/// glass focus rim and grows a little, as the destination cards do.
struct MoreScrollRow<Item: Identifiable, Card: View>: View {
    let items: [Item]
    /// The card's picture (the rim goes round it; captions sit below).
    let pictureSize: CGSize
    var corner: CGFloat
    var spacing: CGFloat = 32
    /// Goes up: focus onto the first card.
    var focusRequest = 0
    let onSelect: (Item) -> Void
    var onFocus: (Bool) -> Void = { _ in }
    /// The hold-Select menu for an item: its name and items (nil: none).
    var menu: ((Item) -> (title: String, entries: [MenuEntry]))? = nil
    @ViewBuilder let card: (Item, _ focused: Bool) -> Card

    @FocusState private var focused: Item.ID?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(items) { item in
                    let isFocused = focused == item.id
                    Button { onSelect(item) } label: {
                        card(item, isFocused)
                            .overlay(alignment: .top) {
                                GlassFocusRim(cornerRadius: corner, lineWidth: Spotlight.outlineWidth)
                                    .frame(width: pictureSize.width, height: pictureSize.height)
                                    .opacity(isFocused ? 1 : 0)
                            }
                            .scaleEffect(isFocused ? 1.06 : 1, anchor: .top)
                            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 18, y: 10)
                            .animation(.easeOut(duration: 0.2), value: isFocused)
                    }
                    .buttonStyle(InertButtonStyle())
                    .focused($focused, equals: item.id)
                    .holdMenu(focused: focused == item.id) { menu?(item).entries ?? [] }
                }
            }
            // Room for the grown card and its shadow.
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .padding(.vertical, -24)
        .onChange(of: focused) { _, now in onFocus(now != nil) }
        .onChange(of: focusRequest) { _, _ in focused = items.first?.id }
    }
}

/// A title on the More page: a portrait poster with the glass rim (the
/// focus rim and a lift when focused).
private struct MorePoster: View {
    let item: MetaItem
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: item.poster ?? item.background, maxDimension: 300)
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
                .overlay { GlassRim(cornerRadius: Spotlight.cornerRadius) }
                .padding(.bottom, 10)
            Text(item.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(focused ? AppGlass.text : AppGlass.textMuted)
                .lineLimit(1)
            if let year = item.year {
                Text(year)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppGlass.textMuted.opacity(0.8))
            }
        }
        .frame(width: 200, alignment: .leading)
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

/// A Detail button's arrival from the billboard: it appears as a small dot
/// and swells into its shape with a liquid spring (a little overshoot),
/// left to right; leaving, it shrinks back into a dot and goes. Plain
/// buttons only — glass flickers under a changing opacity.
/// The billboard → Details swap: a button fades in where it is, one after
/// the other (`index`) — no movement (it used to rise, and before that grow
/// out of a dot).
struct DotGrow: ViewModifier {
    let shown: Bool
    var index = 0

    static let stagger: Double = 0.04

    func body(content: Content) -> some View {
        // In place: the buttons fade in where they are (no rise).
        content
            .opacity(shown ? 1 : 0)
            .animation(shown ? ModeSwap.buttonsIn.delay(Double(index) * Self.stagger) : ModeSwap.buttonsOut,
                       value: shown)
    }
}

/// A Detail button. The primary one (Play / Resume) always shows its icon
/// and title; the others are circles with an icon — and, focused, a small
/// caption under them (Render Lab → Button captions). Nothing ever changes
/// size: focus only lights a button up. The top bar's materials
/// (`GlassPill`): glass at rest, the bright highlight focused. `onHold`:
/// holding Select for half a second runs it instead of the action (a press
/// that became a hold never also taps).
struct DetailActionButton: View {
    @ObservedObject private var probe = RenderProbe.shared
    let icon: String
    let title: String
    let isPrimary: Bool
    let lit: Bool
    /// Working (Play finding a source): a spinner instead of the icon.
    var busy = false
    let action: () -> Void
    var onHold: (() -> Void)? = nil

    /// Its hold menu open (Play).
    @State private var held = false

    static let paintDelay = Duration.milliseconds(50)
    /// The top bar's look at Apple's button size: the app's glass at rest,
    /// the bright glass highlight when focused (a little larger, dark
    /// content) — the one exception to "glass only floats": the title's
    /// controls, on the picture (docs/UI-DESIGN.md §1).
    static let height: CGFloat = 64
    static let textPadding: CGFloat = 25
    static let iconBox: CGFloat = 30
    /// Lighting up / the caption coming in.
    static let open: Animation = .smooth(duration: 0.2)
    /// The caption: small, under the circle.
    static let captionSize: CGFloat = 20
    static let captionGap: CGFloat = 12

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if busy {
                        ProgressView().tint(lit ? .black : .white).scaleEffect(0.8)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: GlassPill.iconSize, weight: .semibold))
                    }
                }
                .frame(width: Self.iconBox, height: Self.iconBox)
                if isPrimary {
                    Text(title)
                        .font(.system(size: GlassPill.textSize, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, isPrimary ? Self.textPadding : 0)
            .frame(width: isPrimary ? nil : Self.height, height: Self.height)
            .foregroundStyle(lit ? FlatControl.contentOnFocus : FlatControl.content)
            // ONE glass layer that never changes; the focus highlight fades
            // in over it. (Swapping glass views on every focus change, and
            // animating their size and a large shadow, dropped frames.)
            .background {
                ZStack {
                    Color.clear.liquidGlass(in: Capsule())
                    Capsule().fill(AppGlass.focusTint).opacity(lit ? 1 : 0)
                }
            }
            .animation(Self.open, value: lit)
            // An icon button's name, under it while focused (outside its
            // frame: the row never moves for it).
            .overlay(alignment: .top) {
                if !isPrimary, probe.flags.buttonCaptions {
                    Text(title)
                        .font(.system(size: Self.captionSize, weight: .medium))
                        .foregroundStyle(AppGlass.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(lit ? 1 : 0)
                        .animation(Self.open, value: lit)
                        .offset(y: Self.height + Self.captionGap)
                }
            }
        }
        .buttonStyle(DetailPressStyle(lit: lit, held: held))
        // Hold Select (Play): straight to its sources — through `HoldMenu`
        // (the press is cancelled: no Play on release), no menu.
        .holdMenu(focused: lit && onHold != nil, direct: true, onHeld: { held = $0 }) {
            onHold.map { [MenuEntry(title: "Choose Source", icon: "list.bullet", run: $0)] } ?? []
        }
    }
}

/// The buttons' size — the cards' rule: focused larger (a scale: a cheap
/// transform), pressed 3 % less, a little more while its hold menu is open.
private struct DetailPressStyle: ButtonStyle {
    let lit: Bool
    let held: Bool
    static let focusScale: CGFloat = 1.07

    func makeBody(configuration: Configuration) -> some View {
        let base = lit ? Self.focusScale : 1
        let scale = held ? base + FixedFocusMetrics.heldGrowth
            : configuration.isPressed ? base - (1 - FixedFocusMetrics.pressScale) : base
        return configuration.label
            .scaleEffect(scale)
            .animation(.easeOut(duration: configuration.isPressed ? 0.12 : 0.2), value: scale)
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
            // A soft plate on focus — reads as selectable without a solid
            // slab shouting over the art (in the page: flat, not glass).
            .background(RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                .fill(FlatControl.rest.opacity(isFocused ? 1 : 0)))
            .overlay(
                RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
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

            VStack(alignment: .leading, spacing: CueSpacing.xl) {
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
                .focusLift(CueFocus.card, lifted, animation: episodeLiftAnimation)
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



