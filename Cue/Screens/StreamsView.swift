import SwiftUI
import UIKit

@MainActor
final class StreamsViewModel: ObservableObject {
    @Published var isLoading = true
    /// When the shown list was found: a search's end, or the time a cached
    /// list (`SourceListCache`) was found — the picker says so.
    @Published private(set) var foundAt: Date?
    @Published var finishedAddons = 0
    @Published var totalAddons = 0
    /// Every add-on asked, in installed order: the picker's tabs.
    @Published var addonNames: [String] = []

    let meta: MetaItem
    let video: MetaVideo?

    /// Every usable link, as the add-ons answered.
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
            if let first = pool.first(where: { $0.addonName == name && !$0.stream.isTorrent }) {
                firstLinkFired = true
                onFirstLink(first)
                return
            }
        }
    }

    /// The running sweep: a newer one (Search Again mid-search) makes an older
    /// one stop adding to the list.
    private var sweep = UUID()

    /// Addons whose stream request has returned (either way).
    @Published private(set) var finishedAddonNames: Set<String> = []

    /// How long each add-on gets to answer. Play waits on the add-ons in
    /// order, so a dead first add-on holds the stage this long; an
    /// AIOStreams search over debrid and indexers is usually in by 10 s.
    static let streamTimeout: TimeInterval = 20

    /// Reset and fetch again (the empty state's Try Again) — bypasses the cache
    /// so the user gets a genuinely fresh sweep.
    func reload(addonManager: AddonManager) async {
        // The running sweep stops adding from here on (it checks `sweep`).
        sweep = UUID()
        pool = []
        entries = []
        addonNames = []
        finishedAddons = 0
        // NOTE: the view resets its one-shot focus latch around this call —
        // `reload` regenerates every entry id, so the previously focused row no
        // longer exists, and the retry button that held focus disappears the
        // moment results arrive.
        await load(addonManager: addonManager, forceRefresh: true)
    }

    /// Asks every add-on that handles the title, a few at a time; each
    /// add-on's links kept in its own order (`entries`).
    func load(addonManager: AddonManager, forceRefresh: Bool = false) async {
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
            rebuildEntries()
            isLoading = false
            return
        }

        failedAddons = [:]
        finishedAddonNames = []
        // The sweep below APPENDS to `pool` and INCREMENTS `finishedAddons`,
        // so both have to start from zero — `reload()` cleared them and this
        // path did not. Re-entering Sources (play a link, press Back) ran a
        // second sweep on top of the first: every source from an addon that
        // had already answered was listed TWICE, `finishedAddons` counted past
        // `totalAddons` so the header read "9/6".
        pool = []
        finishedAddons = 0
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
                        let streams = try await StremioAPI.streams(addon: addon, type: meta.type, id: fetchID, timeout: Self.streamTimeout)
                        let entries = streams
                            .filter(\.isPlayable)
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
            // Rebuilt on throttled batches, so the list doesn't re-diff on
            // every answer while it's being read.
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
                if onFirstLink != nil, !firstLinkFired { rebuildEntries() }
                let now = Date()
                if !pool.isEmpty, now.timeIntervalSince(lastFlush) > 0.4 {
                    rebuildEntries()
                    lastFlush = now
                }
            }
            rebuildEntries()
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

    /// `entries` from the pool: add-on by add-on in installed order, each
    /// add-on's links in its own order.
    private func rebuildEntries() {
        let rank = Dictionary(queriedAddonNames.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        entries = pool.enumerated().sorted {
            let (a, b) = (rank[$0.element.addonName] ?? .max, rank[$1.element.addonName] ?? .max)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        evaluateFirstLink()
    }
}
