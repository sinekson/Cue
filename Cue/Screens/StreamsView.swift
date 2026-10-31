import SwiftUI
import UIKit

@MainActor
final class StreamsViewModel: ObservableObject {
    /// Addon → resolution section → size subsection → rows (see SourceSelection).
    @Published var groups: [AddonSourceGroup] = []
    @Published var isLoading = true
    /// When the shown list was found: a search's end, or the time a cached
    /// list (`SourceListCache`) was found — the picker says so.
    @Published private(set) var foundAt: Date?
    @Published var finishedAddons = 0
    @Published var totalAddons = 0
    /// Addons that returned at least one usable link, in the order they arrived
    /// — drives the filter chips. nil `selectedAddon` = show all (merged).
    @Published var addonNames: [String] = []
    @Published var selectedAddon: String? = nil

    let meta: MetaItem
    let video: MetaVideo?

    /// Every usable link across all addons, kept raw so the addon filter can
    /// re-curate a SINGLE addon's full set (not just what survived the
    /// cross-addon per-tier cap).
    private var pool: [StreamEntry] = []
    /// Every stream addon queried for this title (installed order), whether or
    /// not it returned links — so an addon that came back empty (or with only a
    /// cast action) is still shown, as the user asked ("addon name … None").
    private var queriedAddonNames: [String] = []
    /// Installed addons that were NOT queried, with the reason — a broken
    /// manifest or an id-prefix mismatch used to be completely invisible,
    /// which made "why isn't my addon showing?" undiagnosable from the UI.
    /// `id` is the add-on's manifest URL, not its name: two installed
    /// configurations of the same add-on (two Torrentio/Comet setups) produce
    /// two rows with the SAME name, and a duplicated ForEach id makes SwiftUI
    /// drop or mis-render them.
    @Published var skippedAddons: [(id: String, name: String, reason: String)] = []
    /// Addons whose stream request errored this load, with a short reason
    /// (HTTP code / timeout / …) — rendered as "Not working — <reason>" under
    /// the addon name, distinct from a healthy addon that returned no links.
    @Published var failedAddons: [String: String] = [:]

    /// Compact human reason for a failed addon request.
    nonisolated static func shortReason(for error: Error) -> String {
        switch error {
        case StremioAPIError.badResponse(let code):
            return code == 403 ? "the add-on refused the request (HTTP 403)" : "the add-on returned HTTP \(code)"
        case StremioAPIError.emptyBody:
            return "the add-on sent an empty response"
        case StremioAPIError.badURL:
            return "the add-on's URL is invalid"
        case let urlError as URLError where urlError.code == .timedOut:
            return "the add-on timed out"
        case let urlError as URLError:
            return urlError.localizedDescription
        case is DecodingError:
            return "the add-on sent an unreadable response"
        default:
            return "the add-on didn't respond"
        }
    }
    /// Links kept per resolution×size cell (2160p·10–20 GB …) when filters on.
    private var perTier = 6
    /// Curated filters on (resolution → size tiers, cached first) vs raw
    /// capped-per-addon.
    private var filtersEnabled = true

    init(meta: MetaItem, video: MetaVideo?) {
        self.meta = meta
        self.video = video
    }

    var streamID: String {
        video?.id ?? meta.id
    }

    /// The id actually sent to stream addons — resolved once, then reused so
    /// the cache key and every fetch agree. Two normalizations, both so a
    /// resumed / manually-played title lands on an id Cinemeta/Comet/Torrentio
    /// can resolve (the "Comet unable to get metadata" empty source page):
    ///  1. `tmdb:<n>` → IMDb `tt` (those addons can't serve tmdb ids).
    ///  2. For a series episode, force the canonical `showId:season:episode`
    ///     form instead of trusting a stored `video.id`, which after a
    ///     Continue-Watching round-trip can be the bare show id.
    private var resolvedID: String?
    /// When the user pressed Play. Every stage below logs its offset from this,
    /// so a slow open can be attributed to a stage instead of guessed at.
    var openedAt = Date()
    func stage(_ name: String) {
        NSLog("[CuePlay] +%.2fs %@", Date().timeIntervalSince(openedAt), name)
        // Every stage of Play → picture, on the same clock as the browsing
        // before it and the player after it. This is the seam the two probes
        // used to meet at with a gap in the middle.
        AppProbe.data(String(format: "play +%.2fs  %@",
                             Date().timeIntervalSince(openedAt), name))
    }

    private func effectiveStreamID() async -> String {
        if let resolvedID { return resolvedID }
        var showID = meta.id
        if showID.hasPrefix("tmdb:"), let n = Int(showID.dropFirst("tmdb:".count)),
           // `!isSeries`, not `type != "series"`: a meta typed "tv" went down
           // TMDB's movie endpoint (disjoint id space) and never resolved.
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !meta.isSeries) {
            // A network round-trip BEFORE a single addon is queried. Catalogs
            // sourced from TMDB hand us `tmdb:` ids, so this is on the critical
            // path of most plays.
            showID = tt
            stage("tmdb→imdb id resolved")
        }
        let id: String
        if showID.hasPrefix("tt"), let season = video?.season, let episode = video?.episode {
            id = "\(showID):\(season):\(episode)"
        } else {
            id = video?.id ?? showID
        }
        resolvedID = id
        return id
    }

    var allEntries: [StreamEntry] {
        groups.flatMap(\.entries)
    }

    /// Every link as the add-ons gave them: add-on by add-on in installed
    /// order, each add-on's own order kept (an aggregator like AIOStreams
    /// has already sorted and filtered them). What Details' source panel
    /// lists, and where Play's first link comes from.
    @Published private(set) var entries: [StreamEntry] = []

    /// Play: called once with the FIRST playable link — the first add-on in
    /// order that has one, as soon as it (and every add-on before it) has
    /// answered. Nothing more is waited for.
    var onFirstLink: ((StreamEntry) -> Void)?
    private var firstLinkFired = false

    private func evaluateFirstLink() {
        guard let onFirstLink, !firstLinkFired else { return }
        for name in queriedAddonNames {
            guard finishedAddonNames.contains(name) else { return }   // an earlier add-on comes first
            if let first = pool.first(where: { $0.addonName == name && !$0.stream.isExternal && !$0.stream.isTorrent }) {
                firstLinkFired = true
                onFirstLink(first)
                return
            }
        }
    }

    /// Whether the list has at least one PLAYABLE row.
    ///
    /// `groups` being non-empty is not the same thing: once the sweep finishes,
    /// `rebuildGroups` appends a name-only group for every addon that returned
    /// nothing, so a single stream addon that times out leaves one group of
    /// pure `Text`. The panel used to take that as "we have results", skip the
    /// empty state with its Try Again button, and render a page with NOTHING
    /// focusable — and a Menu press on a focus-less page falls through to tvOS
    /// and suspends the app (see the FocusAnchor note in HomeView).
    var hasPlayableEntries: Bool {
        groups.contains { !$0.entries.isEmpty }
    }

    /// Filter the visible list to a single addon (nil = All). Re-curates from
    /// the raw pool so the chosen addon shows its full per-tier selection.
    func selectAddon(_ name: String?) {
        guard selectedAddon != name else { return }
        selectedAddon = name
        rebuildGroups()
    }

    /// The running sweep: a newer one (Search Again mid-search) makes an older
    /// one stop adding to the list.
    private var sweep = UUID()

    /// Addons whose stream request has returned (either way).
    @Published private(set) var finishedAddonNames: Set<String> = []
    private var sweepStarted = Date()
    /// Set by the view while the Auto Link Selector is armed, so the sweep can
    /// hand back a pick without waiting for every addon.
    var autoLinkPrefs: AutoLinkPreferences?
    var onEarlyAutoLink: ((StreamEntry) -> Void)?
    private var earlyPickFired = false
    /// Longest we will hold out for a preferred addon that hasn't answered.
    private static let preferredAddonWait: TimeInterval = 6
    /// Longest we will keep collecting before picking with no addon preference
    /// left to honour.
    ///
    /// Without one, the early pick fired on the FIRST addon to answer, so with
    /// several installed the selector's choice was decided by network race
    /// order: whoever replied first got to pick, and a cached remux arriving
    /// 200ms later never entered the running. This is the settling time that
    /// buys — short enough to stay imperceptible next to the addon sweep it
    /// overlaps, and cut short the moment the field can no longer improve
    /// (every addon answered, or a link that plays now at the best resolution
    /// this box accepts is already in hand).
    private static let fieldSettleWait: TimeInterval = 2

    /// A pick that is safe to act on BEFORE the sweep has finished.
    ///
    /// The Auto Link Selector used to run only after `load` returned — that is,
    /// after the SLOWEST installed addon had answered or timed out. Your
    /// preferred addon replying in half a second bought nothing; every play was
    /// paced by the worst one in the list, which is why turning the selector on
    /// made starting a title feel slower rather than faster.
    ///
    /// The rule: if the preferred addon has produced a usable match, take it.
    /// If it has answered and produced nothing, fall through to the secondary
    /// on the same terms. Only wait while an addon we actually care about is
    /// still outstanding — and not past `preferredAddonWait`, so one dead addon
    /// can't hold up the whole thing. With no addon left to wait for, take the
    /// best of the whole field once it has settled (`fieldSettleWait`).
    func earlyAutoLinkPick(_ prefs: AutoLinkPreferences) -> StreamEntry? {
        let pool = autoLinkPool(prefs)
        let elapsed = Date().timeIntervalSince(sweepStarted)

        /// Whether an addon can still change the answer: it has to be one we
        /// queried at all, and not yet returned.
        func outstanding(_ name: String) -> Bool {
            let q = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return false }
            guard queriedAddonNames.contains(where: { $0.lowercased().contains(q) }) else { return false }
            return !finishedAddonNames.contains { $0.lowercased().contains(q) }
        }
        func firstFrom(_ name: String) -> StreamEntry? {
            let q = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return nil }
            return pool.first { $0.addonName.lowercased().contains(q) }
        }

        // Patience only means something while a specific addon we are waiting
        // FOR can still answer. It used to be spent on the clock alone, so once
        // the preferred and secondary addons had both replied with nothing the
        // pick still sat out the rest of the 6s for addons no preference names.
        let patient = elapsed < Self.preferredAddonWait

        if let hit = firstFrom(prefs.preferredAddon) { return hit }
        if patient, outstanding(prefs.preferredAddon) { return nil }
        if let hit = firstFrom(prefs.secondaryAddon) { return hit }
        if patient, outstanding(prefs.secondaryAddon) { return nil }

        // No addon preference left to honour: this is now a straight "best
        // available" choice, and the answer keeps improving while addons are
        // still arriving. Four ways to stop collecting, cheapest first — the
        // settle window is the CAP, not the normal wait, so the usual play is
        // still decided in the first few hundred milliseconds.
        guard let best = pool.first else { return nil }
        if finishedAddons >= totalAddons { return best }        // nothing more can arrive
        if elapsed >= Self.fieldSettleWait { return best }      // waited long enough
        if playsNow(best) {
            // Unbeatable: plays now, at the best resolution this box will take.
            if let top = topAllowedTier(prefs),
               ResolutionTier.from(resolutionLabel: best.resolutionLabel) == top { return best }
            // Most of the field is in and what we hold plays now — the
            // stragglers are not worth holding the screen for.
            if finishedAddons * 2 >= totalAddons { return best }
        }
        return nil
    }

    /// Evaluate the early pick and fire it at most once per sweep.
    ///
    /// Called both when an addon answers AND from a deadline timer, because the
    /// per-batch path can only run when an addon answers — which made
    /// `preferredAddonWait` really mean "6s OR the next addon to reply,
    /// whichever is LATER". One slow addon stretched a 6s window to the full
    /// 45s stream timeout.
    func evaluateEarlyAutoLink(_ prefs: AutoLinkPreferences) {
        // Gate on the RAW pool, not on `allEntries`: the latter reads through
        // `groups`, which the sweep only re-flushes every 400ms, so a batch
        // landing inside that window was turned away for having "no entries"
        // while holding the first links of the whole sweep — and turned away
        // before the rebuild that would have fixed it.
        guard !earlyPickFired, !pool.isEmpty else { return }
        rebuildGroups()
        guard let pick = earlyAutoLinkPick(prefs) else { return }
        earlyPickFired = true
        stage("auto-link picked \(pick.addonName) — \(pick.displayName)")
        onEarlyAutoLink?(pick)
    }

    /// Cached title verdicts, keyed by entry id. `evaluateEarlyAutoLink` runs
    /// once per addon batch and re-walks the whole pool each time, so the regex
    /// work behind a verdict is done once per link per sweep, not once per pass.
    private var titleVerdicts: [UUID: StreamTitleVerdict] = [:]

    /// `Stream.isCached` is regex work over three strings, and the auto-pick
    /// ranks the whole pool again on every addon batch. Memoized per entry for
    /// the same reason as `titleVerdicts`.
    private var cachedFlags: [UUID: Bool] = [:]

    /// Does this link play RIGHT NOW? Strict `isCached`, not `isInstant`: a
    /// debrid addon hands back a playable URL for uncached results too (it
    /// downloads on access), and an auto-pick that lands on one is exactly the
    /// wait the selector exists to avoid.
    private func playsNow(_ entry: StreamEntry) -> Bool {
        if let cached = cachedFlags[entry.id] { return cached }
        let cached = entry.stream.isCached
        cachedFlags[entry.id] = cached
        return cached
    }

    /// Rank the whole field for an automatic pick.
    ///
    /// The visible page is grouped by ADDON in INSTALLED order and ranked only
    /// within a group, so its first entry is the best link of whichever addon
    /// happens to sit first — not the best link available. Every automatic path
    /// took that first entry and the comments called it "already sorted
    /// best-first", which it is only inside one addon block: with two addons
    /// installed the selector would take a 720p from the first over a cached
    /// 2160p remux from the second, purely on install order.
    ///
    /// The order, most significant first:
    ///  1. Plays now. An auto-pick that has to wait on a debrid download is the
    ///     failure this feature exists to prevent, and it is the same principle
    ///     `qualityScore` already encodes with its dominant instant bonus.
    ///     Neutral when nothing is cached (a TorrServer-only setup, where every
    ///     link is a torrent), so those setups rank on quality as before — and
    ///     it does NOT lift a 480p link over a higher-resolution one, which is
    ///     the one trade where waiting is clearly the better answer (an
    ///     unlabelled link still counts, since plenty of good debrid links
    ///     carry no resolution at all).
    ///  2. Resolution, in the BOX's own order (`ResolutionTier.displayOrder` —
    ///     on an Apple TV HD a 2160p link is the worst pick, not the best).
    ///  3. `sourceScore`: release ladder, codec, HDR, audio, seeders, size.
    ///     Cached still wins inside a tier, SD included — its +1000 is there.
    ///  4. The page's own order, so equals stay in a stable, familiar sequence.
    private func autoRanked(_ entries: [StreamEntry]) -> [StreamEntry] {
        guard entries.count > 1 else { return entries }
        let tierRank = Dictionary(
            uniqueKeysWithValues: ResolutionTier.displayOrder.enumerated().map { ($1, $0) }
        )
        // Keys computed ONCE per entry rather than on every comparison — a
        // comparator that calls `playsNow` does O(n log n) dictionary lookups
        // for what is O(n) work.
        let keyed = entries.enumerated().map { offset, entry -> (entry: StreamEntry, now: Bool, tier: Int, score: Int, offset: Int) in
            let tier = ResolutionTier.from(resolutionLabel: entry.resolutionLabel)
            return (entry: entry,
                    now: playsNow(entry) && tier != .sd480,
                    tier: tierRank[tier] ?? .max,
                    score: entry.sourceScore,
                    offset: offset)
        }
        return keyed.sorted { l, r in
            if l.now != r.now { return l.now }
            if l.tier != r.tier { return l.tier < r.tier }
            if l.score != r.score { return l.score > r.score }
            return l.offset < r.offset
        }.map(\.entry)
    }

    /// The best resolution an auto-pick can hope for here: the first tier in
    /// the box's own display order that still clears the profile's minimum.
    /// Nothing beats it, so a link that reaches it (and plays now) is worth
    /// taking immediately instead of waiting out the settle window below.
    private func topAllowedTier(_ prefs: AutoLinkPreferences) -> ResolutionTier? {
        let minTier = prefs.minResolution.isEmpty ? nil
            : ResolutionTier.from(resolutionLabel: prefs.minResolution)
        return ResolutionTier.displayOrder.first { tier in
            guard tier != .other else { return false }   // unknown is never "the best"
            guard let minTier else { return true }
            return tier.rawValue <= minTier.rawValue     // lower rawValue = higher resolution
        }
    }

    /// Is this link really the title (and episode) that was asked for?
    /// See `StreamTitleMatcher` — only positive evidence of a MISMATCH rejects.
    func titleVerdict(_ entry: StreamEntry) -> StreamTitleVerdict {
        if let cached = titleVerdicts[entry.id] { return cached }
        let verdict = StreamTitleMatcher.verdict(
            text: StreamTitleMatcher.haystack(
                displayName: entry.displayName,
                displayDetail: entry.displayDetail,
                filename: entry.stream.behaviorHints?.filename
            ),
            title: meta.name,
            year: StreamTitleMatcher.year(fromReleaseInfo: meta.releaseInfo),
            season: video?.season,
            episode: video?.episode,
            ignoring: entry.addonName
        )
        titleVerdicts[entry.id] = verdict
        return verdict
    }

    /// Drop links that name a DIFFERENT title/episode, then float the ones that
    /// positively name the right one above the ones that say nothing either way.
    /// Order within each band is preserved, so every existing rank (resolution,
    /// size, cached, addon preference) still decides between equals.
    ///
    /// Never returns empty when given a non-empty list: if every link looks
    /// wrong, the matcher is more likely to be misreading an unusual naming
    /// convention than the entire source list is to be junk, and refusing to
    /// play anything is the worse failure.
    private func titleFiltered(_ entries: [StreamEntry]) -> [StreamEntry] {
        var confirmed: [StreamEntry] = []
        var unknown: [StreamEntry] = []
        for entry in entries {
            switch titleVerdict(entry) {
            case .confirmed: confirmed.append(entry)
            case .unknown: unknown.append(entry)
            case .rejected: break
            }
        }
        let kept = confirmed + unknown
        return kept.isEmpty ? entries : kept
    }

    /// The entries a profile's Auto Link prefs allow, best-first.
    private func autoLinkPool(_ prefs: AutoLinkPreferences) -> [StreamEntry] {
        let minTier = prefs.minResolution.isEmpty ? nil
            : ResolutionTier.from(resolutionLabel: prefs.minResolution)
        let maxSizeGB = AutoLinkPreferences.sanitizedMaxSizeGB(prefs.maxSizeGB)
        let maxBytes = maxSizeGB > 0 ? Int64(maxSizeGB * 1_073_741_824) : nil
        let pool = allEntries.filter { entry in
            // Never auto-pick an external hand-off (a DMM "cast" entry): the
            // Apple TV can't open it, so the pick died on an alert — with
            // playable links sitting right there. `bestResumeMatch` has
            // always excluded these; the selector and the global auto-play
            // (below) must too. Manual taps still offer them.
            if entry.stream.isExternal { return false }
            // An addon that answered a byte-range request with an HTTP error
            // cannot be cached OR seeked — the proxy fails open so the film
            // plays, and the cache, the scrub previews and seeking are all dead
            // for the rest of the session with nothing on screen to say so.
            if Stream.RangeRefusingAddons.contains(entry.addonName) { return false }
            if prefs.cachedOnly && !entry.stream.isCached { return false }
            if prefs.avoidDolbyVision && entry.stream.isDolbyVision { return false }
            if let minTier, let label = entry.resolutionLabel,
               ResolutionTier.from(resolutionLabel: label).rawValue > minTier.rawValue { return false }
            if let maxBytes, let bytes = entry.sizeBytes, bytes > 0, bytes > maxBytes { return false }
            return true
        }
        return autoRanked(titleFiltered(pool))
    }

    /// Best source for a profile's Auto Link Selector, once the sweep is done:
    /// the pool filtered by the profile's cached-only / min-resolution /
    /// max-size prefs and ranked across every addon (`autoRanked`), preferring
    /// the chosen addon, then the secondary, then the best remaining link.
    /// Unknown resolution/size never disqualifies a link (missing metadata
    /// shouldn't hide a possibly-good source).
    ///
    /// `excluding`: rejection keys of links an auto-pick already tried and
    /// failed to resolve this visit, so the retry moves ON instead of
    /// re-serving the same dead link.
    func autoLinkPick(_ prefs: AutoLinkPreferences, excluding: Set<String> = []) -> StreamEntry? {
        let pool = autoLinkPool(prefs).filter { !excluding.contains($0.rejectionKey) }
        guard !pool.isEmpty else { return nil }
        func firstFromAddon(_ name: String) -> StreamEntry? {
            let q = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return nil }
            return pool.first { $0.addonName.lowercased().contains(q) }
        }
        return firstFromAddon(prefs.preferredAddon)
            ?? firstFromAddon(prefs.secondaryAddon)
            ?? pool.first
    }

    /// Best source to auto-play, honoring cached-only and an optional
    /// case-insensitive title regex. Ranked over the whole field like the
    /// selector (see `autoRanked`) — "Auto-play best source" used to mean
    /// "auto-play the first installed addon's best source".
    func autoPlayPick(cachedOnly: Bool, regex: String, excluding: Set<String> = []) -> StreamEntry? {
        let trimmed = regex.trimmingCharacters(in: .whitespaces)
        let re = trimmed.isEmpty ? nil
            : try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
        // Same name check the Auto Link Selector uses: an auto-play that
        // starts the wrong episode is worse than one that starts nothing.
        return autoRanked(titleFiltered(allEntries)).first { entry in
            if entry.stream.isExternal { return false }   // see autoLinkPool
            if Stream.RangeRefusingAddons.contains(entry.addonName) { return false }
            if excluding.contains(entry.rejectionKey) { return false }
            if cachedOnly && !entry.stream.isCached { return false }
            if let re {
                let hay = "\(entry.addonName) \(entry.displayName) \(entry.displayDetail)"
                let range = NSRange(hay.startIndex..., in: hay)
                if re.firstMatch(in: hay, range: range) == nil { return false }
            }
            return true
        }
    }

    /// Reset and fetch again (the empty state's Try Again) — bypasses the cache
    /// so the user gets a genuinely fresh sweep.
    func reload(addonManager: AddonManager, perTier: Int, filtersEnabled: Bool = true,
                streamTimeout: TimeInterval = 45) async {
        // The running sweep stops adding from here on (it checks `sweep`).
        sweep = UUID()
        groups = []
        pool = []
        entries = []
        // Entry ids are regenerated by the sweep below, so these caches would
        // otherwise grow a dead entry per link on every retry.
        titleVerdicts = [:]
        cachedFlags = [:]
        addonNames = []
        selectedAddon = nil
        finishedAddons = 0
        // NOTE: the view resets its one-shot focus latch around this call —
        // `reload` regenerates every entry id, so the previously focused row no
        // longer exists, and the retry button that held focus disappears the
        // moment results arrive.
        await load(addonManager: addonManager, perTier: perTier, filtersEnabled: filtersEnabled,
                   forceRefresh: true, streamTimeout: streamTimeout)
    }

    /// When a debrid provider is configured, torrent streams (infoHash, no
    /// direct URL) are kept so they can be resolved on selection; otherwise
    /// only directly-playable http(s) streams are shown.
    ///
    /// Each addon's links are grouped into size tiers (250 MB–4 GB … 30 GB+),
    /// debrid-cached links first within each tier, capped at `perTier` — so
    /// the list is short and useful instead of the 150+ near-identical rips
    /// Torrentio alone returns, which is what made scrolling (and selecting
    /// during load) choke.
    func load(addonManager: AddonManager, perTier: Int, filtersEnabled: Bool = true, forceRefresh: Bool = false, streamTimeout: TimeInterval = 45) async {
        let fetchID = await effectiveStreamID()
        stage("stream id ready (\(fetchID))")
        // Self-heal: an addon installed by account sync while its manifest
        // fetch failed is a silent placeholder (no stream resource → never
        // queried, no error anywhere). Retry those now, when the user actually
        // needs them, so e.g. a DMM Cast that installed broken starts working.
        if addonManager.addons.contains(where: { $0.enabled && $0.manifest.isPlaceholder }) {
            // Detached: this is a self-heal for add-ons whose manifest failed to
            // load earlier, and nothing about this play depends on it. Awaiting
            // it put up to N x 5s in front of the first stream request.
            Task { [addonManager] in await addonManager.resolvePlaceholders() }
        }
        let addons = addonManager.streamAddons.filter { $0.handles(id: fetchID) }
        var seenNames = Set<String>()
        queriedAddonNames = addons.compactMap {
            seenNames.insert($0.manifest.name).inserted ? $0.manifest.name : nil
        }
        // Every add-on asked, listed from the start (the picker's filter).
        addonNames = queriedAddonNames
        // Surface every enabled addon that is NOT being queried, with why —
        // and mirror it to the console for debugging.
        var skipped: [(id: String, name: String, reason: String)] = []
        for addon in addonManager.addons where addon.enabled {
            let m = addon.manifest
            if m.isPlaceholder {
                skipped.append((addon.id, m.name, "Not working — couldn't load this add-on. Check its URL or refresh add-ons."))
            } else if m.providesStreams, !addon.handles(id: fetchID) {
                let prefixes = (m.idPrefixes ?? []).joined(separator: ", ")
                skipped.append((addon.id, m.name, "Doesn't claim this title (id \(fetchID) vs prefixes [\(prefixes)])"))
            }
        }
        skippedAddons = skipped
        NSLog("[CueSources] id=%@ querying=%@ skipped=%@",
              fetchID, queriedAddonNames.joined(separator: "|"),
              skipped.map { "\($0.name): \($0.reason)" }.joined(separator: "|"))
        AppProbe.data("sources for \(fetchID): asking \(queriedAddonNames.count)"
                      + " [\(queriedAddonNames.joined(separator: ", "))]"
                      + (skipped.isEmpty ? ""
                         : "  skipped \(skipped.count): "
                           + skipped.map { "\($0.name) (\($0.reason))" }.joined(separator: "; ")))
        totalAddons = addons.count
        self.perTier = perTier
        self.filtersEnabled = filtersEnabled
        isLoading = true

        // Instant path: this title was searched in the last few minutes
        // (`SourceListCache`) — that list, with no add-on sweep at all.
        let sweep = UUID()
        self.sweep = sweep
        if !forceRefresh,
           let (cached, time) = await SourceListCache.shared.list(for: fetchID),
           !cached.isEmpty {
            guard self.sweep == sweep else { return }
            foundAt = time
            pool = cached
            finishedAddons = totalAddons
            failedAddons = [:]   // stale "Not working" diagnostics from a previous sweep
            // Every queried addon is done on this path — the ones with no
            // links otherwise showed "Searching…" forever, since that label
            // keys off this set.
            finishedAddonNames = Set(queriedAddonNames)
            rebuildGroups()
            isLoading = false
            return
        }

        failedAddons = [:]
        finishedAddonNames = []
        sweepStarted = Date()
        // The sweep below APPENDS to `pool` and INCREMENTS `finishedAddons`,
        // so both have to start from zero — `reload()` cleared them and this
        // path did not. Re-entering Sources (play a link, press Back) ran a
        // second sweep on top of the first: every source from an addon that
        // had already answered was listed TWICE, `finishedAddons` counted past
        // `totalAddons` so the header read "9/6", and the auto-link settle
        // window was skipped because its `finished >= total` guard was already
        // true on the first batch.
        pool = []
        finishedAddons = 0
        // Entry ids are regenerated below, so these caches would otherwise
        // keep a dead entry per link from the previous sweep.
        titleVerdicts = [:]
        cachedFlags = [:]
        // Reset per sweep, or a refresh after an early pick could never fire one.
        earlyPickFired = false
        // The deadlines that `fieldSettleWait` and `preferredAddonWait` were
        // always supposed to be. BOTH need a timer: the per-batch path only
        // runs when an addon answers, so a window that expires between two
        // replies would otherwise mean "when the window is up OR the next
        // addon replies, whichever is LATER" — one slow addon stretching a 2s
        // settle to the full 45s stream timeout.
        var autoLinkDeadline: Task<Void, Never>?
        if let prefs = autoLinkPrefs {
            autoLinkDeadline = Task { [weak self] in
                var waited: TimeInterval = 0
                for deadline in [Self.fieldSettleWait, Self.preferredAddonWait] {
                    let remaining = deadline - waited
                    guard remaining > 0 else { continue }
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    waited = deadline
                    self?.evaluateEarlyAutoLink(prefs)
                }
            }
        }
        defer { autoLinkDeadline?.cancel() }
        await withTaskGroup(of: (name: String, entries: [StreamEntry],
                                 failure: (name: String, reason: String)?).self) { group in
            // Bounded window: with a large install this sweep queries dozens of
            // addons. Firing them all at once spikes memory right when the user
            // is waiting on the list, and the tail is set by the slowest addon
            // either way.
            let window = max(1, min(AddonSweepLimits.streams, addons.count))
            var next = 0
            func startNext() {
                guard next < addons.count else { return }
                let addon = addons[next]
                next += 1
                group.addTask { [meta] in
                    do {
                        let streams = try await StremioAPI.streams(addon: addon, type: meta.type, id: fetchID, timeout: streamTimeout)
                        let entries = streams
                            .filter { $0.isPlayable || $0.isExternal }
                            .map { StreamEntry(addonName: addon.manifest.name, stream: $0) }
                        return (addon.manifest.name, entries, nil)
                    } catch {
                        // Request failed (timeout / HTTP error / unreachable) —
                        // record the SPECIFIC reason so the UI can say what's
                        // wrong instead of a generic "didn't respond".
                        NSLog("[CueSources] %@ stream request failed: %@",
                              addon.manifest.name, String(describing: error))
                        AppProbe.warn("sources", "\(addon.manifest.name) — \(error)")
                        return (addon.manifest.name, [], (addon.manifest.name, Self.shortReason(for: error)))
                    }
                }
            }
            for _ in 0..<window { startNext() }
            // Re-curate on throttled batches: recomputing the tier selection per
            // addon made the whole list re-diff several times in the first
            // seconds — exactly while the user starts scrolling it.
            var lastFlush = Date.distantPast
            for await batch in group {
                // Superseded (Search Again): leave the list to the new sweep.
                guard self.sweep == sweep else { group.cancelAll(); return }
                startNext()
                finishedAddons += 1
                finishedAddonNames.insert(batch.name)
                stage("addon \(batch.name) answered (\(batch.entries.count) links, \(finishedAddons)/\(totalAddons))")
                pool.append(contentsOf: batch.entries)
                if let failure = batch.failure { failedAddons[failure.name] = failure.reason }
                // Play's first link: as soon as the add-ons before it are in.
                if onFirstLink != nil, !firstLinkFired { rebuildGroups() }
                let now = Date()
                if !pool.isEmpty, now.timeIntervalSince(lastFlush) > 0.4 {
                    rebuildGroups()
                    lastFlush = now
                }
                // Auto Link Selector: act the MOMENT the answer is knowable,
                // rather than at the end of the sweep. See earlyAutoLinkPick.
                if let prefs = autoLinkPrefs { evaluateEarlyAutoLink(prefs) }
            }
            rebuildGroups()
        }
        guard self.sweep == sweep else { return }
        isLoading = false
        foundAt = Date()

        // Persist for instant re-open — but ONLY a sweep that actually finished.
        // This ran even when `onDisappear` cancelled the task, so backing out at
        // two seconds persisted a one-addon snapshot that the next open then
        // showed as the complete list for the full cache TTL.
        if !pool.isEmpty, !Task.isCancelled, finishedAddons >= totalAddons {
            await SourceListCache.shared.store(pool, for: fetchID)
        }
    }

    /// Recompute `addonNames` + `groups` from the raw pool, honoring the
    /// current addon filter. Called on every load flush and filter change.
    private func rebuildGroups() {
        let rank = Dictionary(queriedAddonNames.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        entries = pool.enumerated().sorted {
            let (a, b) = (rank[$0.element.addonName] ?? .max, rank[$1.element.addonName] ?? .max)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        evaluateFirstLink()
        // Filter chips list EVERY queried addon (installed order), not just ones
        // that returned links — so an empty/cast-only addon stays selectable.
        addonNames = queriedAddonNames
        // Drop a stale filter (e.g. after a reload dropped that addon).
        if let selected = selectedAddon, !queriedAddonNames.contains(selected) {
            selectedAddon = nil
        }
        let scoped0 = selectedAddon.map { name in pool.filter { $0.addonName == name } } ?? pool
        let scoped = SourceSelection.filter(scoped0, streamFilters)
        var built = filtersEnabled
            ? SourceSelection.byAddon(scoped, perTier: perTier)
            : SourceSelection.byAddonUnfiltered(scoped, cap: PlayerSettings.unfilteredPerAddonCap)

        // EVERY queried addon gets a slot from the first rebuild, not just the
        // ones that have answered. Appending these only at the end meant the
        // list changed shape twice underneath the reader: a slow addon that sits
        // early in the installed order inserted its whole group ABOVE the rows
        // being scanned, and then at completion a batch of "None" headings was
        // scattered through the list — both while someone was settling on a
        // candidate. With the skeleton in place results fill into slots that
        // already exist and nothing is ever inserted above the reading position.
        //
        // An addon that has not replied yet renders as pending rather than
        // "None"; `finishedAddonNames` is what tells the row which it is.
        let wanted = selectedAddon.map { [$0] } ?? queriedAddonNames
        let present = Set(built.map(\.addonName))
        for name in wanted where !present.contains(name) {
            built.append(AddonSourceGroup(addonName: name, sections: []))
        }
        // Stable installed-order layout regardless of which addon replied first.
        let order = Dictionary(
            uniqueKeysWithValues: queriedAddonNames.enumerated().map { ($1, $0) }
        )
        groups = built.sorted { (order[$0.addonName] ?? .max) < (order[$1.addonName] ?? .max) }
    }

    /// User stream filters (min resolution, exclude AV1, HDR/DV/cached only).
    var streamFilters = StreamFilterOptions()
}
