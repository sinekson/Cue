import SwiftUI
import AVKit
import Network
import YouTubeKit

/// A counter that moves every time the box's network path changes shape — a
/// VPN tunnel coming up or going down is exactly that kind of change.
///
/// googlevideo mints a playback URL for the connection that asked for it, and
/// the moment the route out of the house changes (tunnel up, tunnel down, or
/// the VPN provider rotating which exit you leave from) the URLs we remembered
/// start answering 403. Nothing in the trailer pipeline noticed: the resolved
/// URLs were cached for half an hour, so enabling a VPN could leave every
/// trailer dead until that window ran out. Stamping each cached entry with the
/// generation it was extracted under makes a path change drop them, without
/// any cache having to know what a VPN is.
enum TrailerNetworkGeneration {
    private static let lock = NSLock()
    private static var value: UInt64 = 0
    /// The shape of the last path we saw. `nil` until the first callback,
    /// which only establishes the baseline — the app didn't change networks by
    /// launching.
    private static var lastShape: String?

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let shape = TrailerNetworkGeneration.shape(of: path)
            TrailerNetworkGeneration.lock.withLock {
                guard TrailerNetworkGeneration.lastShape != shape else { return }
                if TrailerNetworkGeneration.lastShape != nil {
                    TrailerNetworkGeneration.value &+= 1
                }
                TrailerNetworkGeneration.lastShape = shape
            }
        }
        monitor.start(queue: DispatchQueue(label: "cue.trailer.path"))
        return monitor
    }()

    /// Reading this also starts the monitor the first time, so nothing has to
    /// remember to boot it.
    static var current: UInt64 {
        _ = monitor
        return lock.withLock { value }
    }

    /// What we consider "the same network". `usesInterfaceType(.other)` is how
    /// a tunnel shows up, and the interface list catches a VPN that reconnects
    /// onto a fresh `utun` (and so, almost always, a fresh exit address).
    private static func shape(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.name)/\($0.type)" }
            .sorted()
            .joined(separator: ",")
        return "\(path.status)|tunnel:\(path.usesInterfaceType(.other))|\(interfaces)"
    }
}

/// A trailer line to the console and the Log (`trailer` events), so a TV
/// evening shows why a trailer did or didn't come.
nonisolated func trailerLog(_ format: String, _ args: CVarArg...) {
    let line = String(format: format, arguments: args)
    NSLog("[CueTrailer] %@", line)
    PlayerProbe.event("trailer", line)
}

/// Resolves a YouTube video key to something AVPlayer can play. tvOS has no
/// WebKit, so the iframe embed is out — YouTubeKit extracts native streams.
///
/// YouTube only *muxes* audio+video up to ~720p; 1080p and up exist solely as
/// separate adaptive tracks (DASH), so a 1080p trailer means merging a
/// video-only and an audio-only stream into one composition.
///
/// This used to always take the single muxed URL for a fast start, which
/// capped every trailer at 720p (often 360/480p, since the muxed ladder is
/// thin). Resolution wins now: the merge is used whenever it is genuinely
/// sharper than the best muxed stream, and the muxed fast path is kept for the
/// case where it is already as good. The old objection — that merging is slow
/// to start — was mostly the merge loading its two remote assets one after the
/// other; `mergedItem` now loads them concurrently.
enum TrailerResolver {
    /// How many of TMDB's ranked trailers to try before giving up on a title.
    ///
    /// One was not enough. A trailer is a YouTube video like any other and
    /// plenty of them are geo-restricted, so the top-ranked one can be
    /// unplayable from wherever the connection comes OUT — the ordinary case
    /// when the box is on a VPN whose exit sits in another country. TMDB
    /// usually lists several (the studio's, a distributor's, a regional cut)
    /// and the ones after the first are frequently not restricted at all.
    /// Bounded because every miss costs a full extraction (a cut below
    /// `minimumHeight` counts as a miss too); when the first three fail the
    /// rest nearly always fail the same way (NuvioTV's count).
    static let maxCandidates = 3

    /// The lowest a trailer over the picture may be: a soft 360p cut over a
    /// sharp backdrop looks worse than the still, so it is skipped for the
    /// next key — none good enough, the still stays. Not on Apple TV HD,
    /// which plays the muxed stream (360p) on purpose.
    static let minimumHeight = 720

    /// Ask YouTube for a video's streams, local extractor first and the remote
    /// extraction service after it — but not when YouTube refused us (its
    /// bot check, or a page that isn't the video's): the remote service only
    /// tells this device what to ask, from this same address.
    ///
    /// Two separate calls rather than `methods: [.local, .remote]`, for one
    /// reason the combined form does not cover: a local extraction that
    /// returns an EMPTY list without throwing satisfies the combined call,
    /// which then hands back nothing at all. Here that counts as a miss and
    /// the remote extractor still gets its turn.
    ///
    /// Note that neither form reaches the remote extractor unless YouTubeKit
    /// itself is patched — its availability pre-check parses the watch page
    /// before it walks the method list, and used to abort everything when that
    /// page was unreadable. See the CUE PATCH in
    /// `Vendor/YouTubeKit/Sources/YouTubeKit/YouTube.swift`.
    private static func extractStreams(youtubeKey: String) async -> (streams: [YouTubeKit.Stream], hls: URL?)? {
        // A stale session (every client asking to sign in, no bot check
        // named) is asked once more, with the fresh page config YouTubeKit
        // fetches after dropping the old one.
        for attempt in 0..<2 {
            do {
                let youtube = YouTube(videoID: youtubeKey, methods: [.local])
                let streams = try await youtube.streams
                // The same answer carries the HLS manifest (no request of its own).
                let hls = try? await youtube.livestreams.first?.url
                if !streams.isEmpty { return (streams, hls) }
                trailerLog("local extraction returned nothing for %@ — trying remote", youtubeKey)
                break
            } catch {
                let kit = error as? YouTubeKitError
                if kit == .staleSession, attempt == 0, !Task.isCancelled {
                    trailerLog("%@: YouTube's session gone stale — a fresh one", youtubeKey)
                    continue
                }
                // Age-restricted: the remote extractor spends ~10 s and fails too.
                if kit == .videoAgeRestricted || String(describing: error).contains("AgeRestricted") {
                    refuse(youtubeKey: youtubeKey, reason: "age restricted", days: 30)
                    return nil
                }
                // The remote extractor asks from this address too: no use.
                if kit == .botCheck || kit == .rateLimited {
                    holdOff(kit == .botCheck ? "YouTube's bot check" : "YouTube's rate limit (429)")
                    return nil
                }
                if kit == .regexMatchError {
                    trailerLog("YouTube's page unreadable for %@ — refused", youtubeKey)
                    return nil
                }
                trailerLog("local extraction failed for %@: %@ — trying remote",
                      youtubeKey, String(describing: error))
                break
            }
        }
        // The hero moved on (or the page closed) and took the URLSession
        // requests with it — that is not YouTube refusing us, and the remote
        // extractor would only be cancelled the same way.
        guard !Task.isCancelled else { return nil }
        do {
            let youtube = YouTube(videoID: youtubeKey, methods: [.remote])
            let streams = try await youtube.streams
            let hls = try? await youtube.livestreams.first?.url
            return streams.isEmpty ? nil : (streams, hls)
        } catch {
            if (error as? YouTubeKitError) == .rateLimited { holdOff("YouTube's rate limit (429)") }
            trailerLog("extraction failed for %@: %@", youtubeKey, String(describing: error))
            return nil
        }
    }

    /// YouTube's HLS master playlist, rewritten for the player: only H.264
    /// (decoded in hardware; VP9 isn't) and — but on Apple TV HD — nothing
    /// below `minimumHeight`, so the player adapts between 720p and 1080p and
    /// never drops to a soft cut. One URL, segments, adaptive: it starts
    /// sooner and doesn't stall the way the merged pair (two whole files)
    /// does. URIs made absolute: it's served from our own scheme
    /// (`TrailerPlaylist`). Nil: no manifest, or nothing in it good enough.
    private static func hlsPlaylist(manifest: URL, key: String) async -> (text: String, height: Int)? {
        guard let (data, response) = try? await URLSession.shared.data(from: manifest),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            trailerLog("%@: HLS manifest unreadable", key)
            return nil
        }
        func attribute(_ name: String, in line: String) -> String? {
            guard let range = line.range(of: name + "=") else { return nil }
            var rest = line[range.upperBound...]
            if rest.first == "\"" { rest = rest.dropFirst(); return String(rest.prefix { $0 != "\"" }) }
            return String(rest.prefix { $0 != "," })
        }
        let lines = text.components(separatedBy: "\n")
        var out: [String] = [], height = 0, total = 0, codecs: Set<String> = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard line.hasPrefix("#EXT-X-STREAM-INF"), index < lines.count else {
                out.append(line)
                continue
            }
            let uri = lines[index]
            index += 1
            total += 1
            let codec = attribute("CODECS", in: line) ?? ""
            let tall = attribute("RESOLUTION", in: line)?.split(separator: "x").last.flatMap { Int($0) } ?? 0
            guard codec.hasPrefix("avc1"), PerformanceProfile.isLowPower || tall >= minimumHeight else { continue }
            out.append(line)
            out.append(URL(string: uri, relativeTo: manifest)?.absoluteString ?? uri)
            height = max(height, tall)
            codecs.insert(codec)
        }
        guard height > 0 else {
            trailerLog("%@: HLS has nothing good enough (%d variants)", key, total)
            return nil
        }
        trailerLog("%@: HLS up to %dp, %d of %d variants (%@)", key, height,
              out.filter { $0.hasPrefix("#EXT-X-STREAM-INF") }.count, total,
              codecs.sorted().joined(separator: " | "))
        return (out.joined(separator: "\n"), height)
    }

    /// Bound AVPlayer's read-ahead on the constrained boxes. With no
    /// preference set it buffers at its own appetite — fine on 4 GB, but a
    /// trailer is a MUTED PREVIEW playing beside a browsing UI on the 2–3 GB
    /// boxes, and its buffer competes with poster decodes for the same RAM.
    @discardableResult
    private static func budgeted(_ item: AVPlayerItem) -> AVPlayerItem {
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            item.preferredForwardBufferDuration = 10
        }
        return item
    }

    /// googlevideo playback URLs are tied to the InnerTube CLIENT that
    /// extracted them (the `c=` query param) — YouTube serves them only to a
    /// matching User-Agent, and AVPlayer's default UA gets "Cannot Open"
    /// (-11828). Rebuild each request with the extracting client's UA.
    private static func asset(for url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent(for: url)]
        ])
    }

    /// The User-Agent of the client that minted `url` (`asset(for:)`).
    private static func userAgent(for url: URL) -> String {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value
        let userAgent: String
        switch client {
        case "ANDROID_VR":
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        case "ANDROID":
            userAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
        case "ANDROID_MUSIC":
            userAgent = "com.google.android.apps.youtube.music/5.16.51 (Linux; U; Android 11) gzip"
        case "ANDROID_EMBEDDED_PLAYER":
            userAgent = "com.google.android.youtube/18.11.34 (Linux; U; Android 11) gzip"
        // The clients below were missing, and every one of them is an APP
        // client — the kind googlevideo actually checks the agent for. They
        // are not exotic: the local extractor falls through to them when the
        // first choice is refused, and the REMOTE extractor (the one that
        // takes over whenever YouTube won't talk to this address directly,
        // which is the normal state of affairs from a VPN exit) hands back
        // whichever client got through. Extraction then succeeded and
        // playback died with "Cannot Open" — a trailer that resolves and
        // never starts. Agents lifted from YouTubeKit's own client table so
        // they match the request that minted the URL.
        case "IOS":
            userAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        case "IOS_MUSIC":
            userAgent = "com.google.ios.youtubemusic/5.21 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)"
        case "TVHTML5":
            userAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
        case "TVHTML5_SIMPLY_EMBEDDED_PLAYER":
            userAgent = "Mozilla/5.0"
        default:
            // WEB, VISIONOS, MWEB, WEB_EMBEDDED_PLAYER and friends are
            // browser clients — a browser agent is the matching one.
            userAgent = "Mozilla/5.0"
        }
        return userAgent
    }

    /// Merge a remote video-only and audio-only track into one playable asset.
    ///
    /// `@MainActor` because `AVPlayerItem.init(asset:)` is main-actor isolated
    /// in the current SDK and this was calling it from a nonisolated async
    /// context — a warning today and a hard error under Swift 6. Nothing is
    /// blocked by the annotation: every expensive step in here is an `await`
    /// on AVFoundation's own loaders, which suspend rather than spin, and the
    /// one caller (`playerItem`) is already reached from a `.task` on main.
    @MainActor
    private static func mergedItem(video: URL, audio: URL) async -> AVPlayerItem? {
        let videoAsset = asset(for: video)
        let audioAsset = asset(for: audio)
        let composition = AVMutableComposition()
        do {
            // CONCURRENTLY. Each of these is a network round trip for the
            // asset's moov atom, and running them one after another is most of
            // what made a merged trailer slower to open than a muxed one —
            // which is why the muxed stream (and its 720p ceiling) used to be
            // preferred outright.
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let videoDuration = videoAsset.load(.duration)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)

            guard let vTrack = try await videoTracks.first else { return nil }
            let range = try await CMTimeRange(start: .zero, duration: videoDuration)
            let vComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try vComp?.insertTimeRange(range, of: vTrack, at: .zero)
            if let aTrack = try await audioTracks.first {
                let aComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                // The audio track can be a hair shorter than the video; clamp
                // so `insertTimeRange` can't throw on the tail and lose the
                // whole composition (and with it the 1080p path).
                let audioDuration = try await aTrack.load(.timeRange).duration
                let audioRange = CMTimeRange(start: .zero,
                                             duration: min(range.duration, audioDuration))
                try aComp?.insertTimeRange(audioRange, of: aTrack, at: .zero)
            }
            return budgeted(AVPlayerItem(asset: composition))
        } catch {
            trailerLog("merge failed: %@", String(describing: error))
            return nil
        }
    }

    /// The backdrop trailer behind the billboard and Details.
    ///
    /// Resolution is chosen the same way `playerItem` chooses it — the merged
    /// adaptive pair when it beats the muxed ladder, which in practice means
    /// 1080p instead of 720p or worse. The client-matched User-Agent is baked
    /// in — see `asset(for:)`.
    ///
    /// Extraction is the slow step (seconds; the remote fallback ~10 s), so
    /// what it finds is kept ON DISK (`stored`): a key's URLs until
    /// googlevideo's own expiry (`expire=`, hours), and a key that will never
    /// do — age-restricted, below `minimumHeight`, nothing playable — for 30
    /// days. A title's misses cost once, not at every launch, and the
    /// billboard's titles are resolved ahead (`warm`).
    /// Guarded by `backdropCacheLock`: Home's billboard, its warm-up and a
    /// Details page all resolve at once, off the main actor.
    private static let backdropCacheLock = NSLock()

    /// What extraction settled on for one key. Both URLs are remembered, not
    /// just one, because the 1080p choice is a PAIR of adaptive streams —
    /// and `muxedFallback` keeps a single self-contained URL around so a
    /// failed merge degrades to a lower-resolution trailer WITH audio rather
    /// than to a silent one.
    private struct BackdropChoice: Codable {
        let video: URL
        let audio: URL?
        let muxedFallback: URL?
        /// The rewritten HLS master playlist (`hlsPlaylist`) — played first;
        /// the URLs above are its fallback.
        var playlist: String?
        var height: Int
        let at: Date
        /// The network path these URLs were minted for — see
        /// `TrailerNetworkGeneration` (on loading from disk: the current one;
        /// a dead URL is caught by the player, which resolves again).
        var generation: UInt64
        /// When to stop handing these out: googlevideo's expiry less a
        /// margin, else half an hour on.
        var expires: Date {
            // A stream's `expire=`; a manifest's `/expire/…/` in its path.
            let path = video.pathComponents
            let stamp = (URLComponents(url: video, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "expire" })?.value
                ?? path.firstIndex(of: "expire").flatMap { path.indices.contains($0 + 1) ? path[$0 + 1] : nil })
                .flatMap(TimeInterval.init)
            return stamp.map { Date(timeIntervalSince1970: $0 - 15 * 60) } ?? at.addingTimeInterval(30 * 60)
        }
    }
    /// A key that will never do, and why.
    private struct Refusal: Codable {
        let reason: String
        let at: Date
        /// How long it holds: a property of the video (age) 30 days; what
        /// one answer happened to offer (a low cut, nothing playable) a day —
        /// another client may well have more.
        var days: Double?
        var life: TimeInterval { (days ?? 30) * 24 * 60 * 60 }
    }
    private struct Stored: Codable {
        var choices: [String: BackdropChoice] = [:]
        var refused: [String: Refusal] = [:]
    }
    private static let storeURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CueCache/trailers.json")
    private static let storeQueue = DispatchQueue(label: "cue.trailer.store", qos: .utility)
    /// Read from disk at first use, expired entries dropped.
    private static var stored: Stored = {
        guard let data = try? Data(contentsOf: storeURL),
              var value = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        let now = Date(), generation = TrailerNetworkGeneration.current
        value.choices = value.choices.filter { $0.value.expires > now }
            .mapValues { var choice = $0; choice.generation = generation; return choice }
        value.refused = value.refused.filter { now.timeIntervalSince($0.value.at) < $0.value.life }
        return value
    }()
    /// The found trailers' links forgotten (Settings → Storage); the
    /// refusals stay, so YouTube isn't asked again for titles it refused.
    static func clearChoices() {
        backdropCacheLock.withLock {
            stored.choices = [:]
            saveLocked()
        }
    }
    /// Written behind, in order. Called under `backdropCacheLock`.
    private static func saveLocked() {
        let snapshot = stored
        storeQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
        }
    }
    /// Extractions running, one per key however many ask (the warm-up and a
    /// rest on the same title), with how many are waiting on it: the last
    /// one to leave cancels it (focus moved on: YouTube isn't asked for
    /// what no one will see — every focus move used to run one to its end).
    private static var resolving: [String: (task: Task<BackdropChoice?, Never>, token: UUID, askers: Int)] = [:]

    /// Keys whose extraction just failed, and when — in memory only (a
    /// failure can be the network's).
    ///
    /// Successes were remembered and failures were not, which is exactly
    /// backwards for load: every time the viewer's focus passed back over a
    /// title we could not extract, we asked YouTube again. Browsing a row of
    /// them is then a burst of failing requests from one address — and a burst
    /// is what earns a bot-check page, whose unparseable HTML is itself the
    /// `regexMatchError` that made the extraction fail. The retry storm feeds
    /// the thing causing it. Short enough that a genuinely transient failure
    /// costs one browse, long enough to stop the storm.
    /// Keys whose HLS failed to play this run: the merged pair instead.
    private static var hlsFailed: Set<String> = []
    private static var backdropFailureCache: [String: (at: Date, generation: UInt64)] = [:]
    private static let backdropFailureTTL: TimeInterval = 10 * 60
    /// The generation the URLs and failures were last swept for.
    private static var cachedGeneration: UInt64 = 0

    /// Drop the URLs and failures of a network we are no longer on (the
    /// refusals stay: they're the videos', not the network's). Called under
    /// `backdropCacheLock`.
    private static func purgeIfPathChangedLocked(_ generation: UInt64) {
        guard cachedGeneration != generation else { return }
        cachedGeneration = generation
        guard !stored.choices.isEmpty || !backdropFailureCache.isEmpty else { return }
        stored.choices.removeAll()
        saveLocked()
        // The failures go too, and that is the point: a burst of them recorded
        // while a tunnel was coming up would otherwise keep every one of those
        // titles trailer-less for ten more minutes after it settled.
        backdropFailureCache.removeAll()
        trailerLog("network path changed — dropped the resolved-URL cache")
    }

    /// Remember that a key wouldn't extract — but only if the network we
    /// failed on is still the network we are on. A slow extraction can finish
    /// AFTER a tunnel came up, and a failure earned on the old path must not
    /// be allowed to sit out the next ten minutes on the new one.
    private static func rememberFailure(youtubeKey: String, generation: UInt64) {
        // A cancelled extraction is not a failed one.
        guard !Task.isCancelled else { return }
        backdropCacheLock.withLock {
            purgeIfPathChangedLocked(TrailerNetworkGeneration.current)
            guard cachedGeneration == generation else { return }
            backdropFailureCache[youtubeKey] = (Date(), generation)
        }
    }

    /// YouTube refusing this address — its "confirm you're not a bot" or a
    /// 429, nothing else (an ordinary failure says nothing about the
    /// address): no trailer resolved for a while, every request would only
    /// keep the flag on. A minute, doubling with each strike up to 15
    /// (NuvioTV's); a success clears it (30 min after any three failures
    /// was before: a minute of browsing took trailers away for half an hour).
    private static func holdOff(_ reason: String) {
        let (pause, strike): (TimeInterval, Int) = backdropCacheLock.withLock {
            strikes += 1
            let pause = min(holdOffMax, holdOffBase * pow(2, Double(strikes - 1)))
            heldOffUntil = Date().addingTimeInterval(pause)
            return (pause, strikes)
        }
        trailerLog("%@ — no trailers for %.0f min (strike %d)", reason, pause / 60, strike)
    }
    /// Kept in the defaults: a relaunch (or a new build) mustn't start
    /// asking again at once.
    private static var heldOffUntil: Date? {
        get { UserDefaults.standard.object(forKey: "cue.trailers.heldOffUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "cue.trailers.heldOffUntil") }
    }
    private static let holdOffBase: TimeInterval = 60
    private static let holdOffMax: TimeInterval = 15 * 60
    private static var strikes = 0

    /// A key extracted: YouTube answers this address again.
    private static func noteSuccess() {
        backdropCacheLock.withLock {
            strikes = 0
            heldOffUntil = nil
        }
    }

    /// Remember that a key won't do (for its `Refusal.life`).
    private static func refuse(youtubeKey: String, reason: String, days: Double = 1) {
        trailerLog("%@: %@ — not used for %.0f day(s)", youtubeKey, reason, days)
        backdropCacheLock.withLock {
            stored.refused[youtubeKey] = Refusal(reason: reason, at: Date(), days: days)
            saveLocked()
        }
    }

    /// Forget what we resolved for a key. The caller is a player that got a
    /// dead URL: a cached googlevideo link minted on a different path answers
    /// 403 rather than video, and without this the next visit to the title
    /// would cheerfully hand out the same dead link until it expired.
    static func invalidate(youtubeKey: String) {
        backdropCacheLock.withLock {
            // Its HLS failing: resolved again, without it.
            if stored.choices[youtubeKey]?.playlist != nil { hlsFailed.insert(youtubeKey) }
            stored.choices.removeValue(forKey: youtubeKey)
            saveLocked()
            // Not a failure to EXTRACT — re-extracting is exactly what should
            // happen next — so the failure cache must not pick it up either.
            backdropFailureCache.removeValue(forKey: youtubeKey)
        }
    }

    /// The first of `candidates` that resolves, with the key it came from.
    /// See `maxCandidates` for why more than one is tried.
    /// A remembered link found dead is extracted again once; a fresh one
    /// dead goes on to the next key.
    static func backdropItem(candidates: [String]) async -> (item: AVPlayerItem, youtubeKey: String)? {
        for key in candidates.prefix(maxCandidates) {
            for _ in 0..<2 {
                guard !Task.isCancelled else { return nil }
                guard let choice = await choice(youtubeKey: key), !Task.isCancelled else { break }
                if let item = await backdropPlayerItem(choice, key: key) { return (item, key) }
                guard !Task.isCancelled else { return nil }
                invalidate(youtubeKey: key)
                if Date().timeIntervalSince(choice.at) < 60 { break }
            }
        }
        return nil
    }

    /// One of `candidates` resolved already (kept, not expired): no
    /// request to YouTube to play it.
    static func isResolved(_ candidates: [String]) -> Bool {
        backdropCacheLock.withLock {
            candidates.prefix(maxCandidates).contains { stored.choices[$0].map { $0.expires > Date() } ?? false }
        }
    }

    /// Asking YouTube is paused (`holdOff`).
    static var heldOff: Bool {
        backdropCacheLock.withLock { heldOffUntil.map { $0 > Date() } ?? false }
    }

    /// Resolved ahead, nothing built: the first of `candidates` that will
    /// play.
    @discardableResult
    static func prepare(candidates: [String]) async -> String? {
        for key in candidates.prefix(maxCandidates) {
            guard !Task.isCancelled else { return nil }
            if await choice(youtubeKey: key) != nil { return key }
        }
        return nil
    }

    /// How many of the billboard's titles are resolved ahead (`warm`).
    static let warmCount = 3

    /// Titles' trailers resolved ahead, one after another, `warmGap` apart —
    /// a burst from one address earns YouTube's bot check. What's kept costs
    /// nothing.
    static func warm(_ titles: [(item: MetaItem, season: Int?, aired: Date?)]) async {
        for (index, title) in titles.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(warmGap)) }
            guard !Task.isCancelled else { return }
            let keys = await TMDBService.trailerKeys(id: title.item.id, type: title.item.type,
                                                     season: title.season, aired: title.aired)
            await prepare(candidates: keys)
        }
    }

    private static let warmGap: Double = 4

    /// What a key resolves to: kept, refused, or extracted (once).
    private static func choice(youtubeKey: String) async -> BackdropChoice? {
        let generation = TrailerNetworkGeneration.current
        let task: Task<BackdropChoice?, Never>? = backdropCacheLock.withLock {
            purgeIfPathChangedLocked(generation)
            if let hit = stored.choices[youtubeKey], hit.expires > Date() {
                return Task { hit }
            }
            if let refused = stored.refused[youtubeKey],
               Date().timeIntervalSince(refused.at) < refused.life { return nil }
            if let failed = backdropFailureCache[youtubeKey],
               Date().timeIntervalSince(failed.at) < backdropFailureTTL { return nil }
            if let until = heldOffUntil, until > Date() { return nil }
            if var running = resolving[youtubeKey] {
                running.askers += 1
                resolving[youtubeKey] = running
                return running.task
            }
            let token = UUID()
            let task = Task.detached(priority: .userInitiated) { () -> BackdropChoice? in
                let choice = await extractChoice(youtubeKey: youtubeKey, generation: generation)
                backdropCacheLock.withLock {
                    if resolving[youtubeKey]?.token == token { resolving[youtubeKey] = nil }
                }
                return choice
            }
            resolving[youtubeKey] = (task, token, 1)
            return task
        }
        guard let task else { return nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            let last: Bool = backdropCacheLock.withLock {
                guard var running = resolving[youtubeKey], running.task == task else { return false }
                running.askers -= 1
                if running.askers > 0 { resolving[youtubeKey] = running; return false }
                resolving[youtubeKey] = nil
                return true
            }
            if last { task.cancel() }
        }
    }

    private static func extractChoice(youtubeKey: String, generation: UInt64) async -> BackdropChoice? {
        guard let found = await extractStreams(youtubeKey: youtubeKey) else {
            rememberFailure(youtubeKey: youtubeKey, generation: generation)
            return nil
        }
        noteSuccess()
        let streams = found.streams
        let skipHLS = backdropCacheLock.withLock { hlsFailed.contains(youtubeKey) }
        var hls: (text: String, height: Int)?
        if !skipHLS, let manifest = found.hls { hls = await hlsPlaylist(manifest: manifest, key: youtubeKey) }
        let playable = streams.filter { $0.isNativelyPlayable }
        let muxed = playable.filterVideoAndAudio().highestResolutionStream()
        let adaptive = playable.filterVideoOnly().highestResolutionStream()
        let muxedHeight = muxed?.videoResolution ?? 0
        let adaptiveHeight = adaptive?.videoResolution ?? 0

        var choice: BackdropChoice
        // Apple TV HD: same rule as `playerItem` — the muxed single URL over
        // a two-connection composition merge (see the note there).
        if !PerformanceProfile.isLowPower, adaptiveHeight > muxedHeight, let adaptive {
            // 1080p: video-only plus its own audio track, merged at play time.
            choice = BackdropChoice(video: adaptive.url,
                                    audio: playable.filterAudioOnly().highestAudioBitrateStream()?.url,
                                    muxedFallback: muxed?.url,
                                    height: adaptiveHeight, at: Date(), generation: generation)
        } else if let muxed {
            choice = BackdropChoice(video: muxed.url, audio: nil, muxedFallback: muxed.url,
                                    height: muxedHeight, at: Date(), generation: generation)
        } else if let adaptive {
            choice = BackdropChoice(video: adaptive.url,
                                    audio: playable.filterAudioOnly().highestAudioBitrateStream()?.url,
                                    muxedFallback: nil,
                                    height: adaptiveHeight, at: Date(), generation: generation)
        } else if hls != nil, let manifest = found.hls {
            choice = BackdropChoice(video: manifest, audio: nil, muxedFallback: nil,
                                    height: 0, at: Date(), generation: generation)
        } else {
            refuse(youtubeKey: youtubeKey, reason: "nothing playable")
            return nil
        }
        if let hls {
            choice.playlist = hls.text
            choice.height = hls.height
        }
        if !PerformanceProfile.isLowPower, choice.height < minimumHeight {
            refuse(youtubeKey: youtubeKey, reason: "\(choice.height)p")
            return nil
        }
        backdropCacheLock.withLock {
            // The path could have moved under us during a multi-second
            // extraction; only keep what still belongs to the current one.
            purgeIfPathChangedLocked(TrailerNetworkGeneration.current)
            guard cachedGeneration == choice.generation else { return }
            stored.choices[youtubeKey] = choice
            saveLocked()
        }
        trailerLog("backdrop %@: %dp (%@)", youtubeKey, choice.height,
              choice.playlist != nil ? "HLS" : choice.audio == nil ? "muxed" : "merged")
        return choice
    }

    /// Build the item for a resolved backdrop choice.
    ///
    /// `@MainActor` for the same reason `mergedItem` is: `AVPlayerItem.init`
    /// is main-actor isolated. A merge that fails falls back to the muxed URL
    /// — a lower-resolution trailer that still has SOUND, which matters
    /// because the Detail page un-mutes this item.
    @MainActor
    private static func backdropPlayerItem(_ choice: BackdropChoice, key: String) async -> AVPlayerItem? {
        // The first thing the player will fetch, asked for one byte first: a
        // link YouTube no longer serves (403: another address, expired early)
        // never reaches the player (NuvioTV's check). No answer in 2 s isn't
        // proof: played anyway.
        let first = choice.playlist.flatMap { $0.components(separatedBy: "\n").first { $0.hasPrefix("http") } }
            .flatMap(URL.init(string:)) ?? choice.video
        if await isDead(first, agent: choice.playlist == nil) {
            trailerLog("%@: link dead (%@)", key, choice.playlist != nil ? "HLS" : "stream")
            return nil
        }
        if let playlist = choice.playlist {
            return budgeted(AVPlayerItem(asset: TrailerPlaylist.shared.asset(key: key, playlist: playlist)))
        }
        guard let audio = choice.audio else {
            return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
        }
        if let merged = await mergedItem(video: choice.video, audio: audio) {
            return merged
        }
        if let fallback = choice.muxedFallback {
            trailerLog("backdrop merge failed — falling back to the muxed stream")
            return budgeted(AVPlayerItem(asset: asset(for: fallback)))
        }
        return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
    }
}

extension TrailerResolver {
    /// A definite refusal (4xx) for `url`; a timeout or network error isn't.
    /// `agent`: googlevideo's streams want their client's User-Agent.
    nonisolated static func isDead(_ url: URL, agent: Bool) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if agent { request.setValue(userAgent(for: url), forHTTPHeaderField: "User-Agent") }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (400..<500).contains(code)
    }
}

/// Serves the rewritten HLS master playlists (`TrailerResolver.hlsPlaylist`)
/// to AVPlayer under our own scheme; everything it points at (the variant
/// playlists, the segments) AVPlayer fetches from YouTube itself.
final class TrailerPlaylist: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = TrailerPlaylist()
    private static let scheme = "cue-trailer"
    private let queue = DispatchQueue(label: "cue.trailer.playlist")
    private let lock = NSLock()
    private var playlists: [String: Data] = [:]

    func asset(key: String, playlist: String) -> AVURLAsset {
        lock.withLock { playlists[key] = Data(playlist.utf8) }
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://playlist/\(key).m3u8")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }
        let key = url.deletingPathExtension().lastPathComponent
        guard let data = lock.withLock({ playlists[key] }) else { return false }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
        return true
    }
}

// MARK: - The billboard's trailer

/// Something full screen is playing (the player, Details' trailer): no
/// billboard trailer starts, a playing one pauses.
@MainActor
final class TrailerGate: ObservableObject {
    static let shared = TrailerGate()
    @Published var playerUp = false
    /// A full-screen page over the app (the profile gate, the welcome).
    @Published var coverUp = false
    /// No press for `idleAfter`: no trailer starts by itself (one playing
    /// plays on) until the next press — a TV left on Home isn't a trailer
    /// jukebox, and YouTube isn't asked all evening.
    @Published private(set) var idle = false
    static let idleAfter: TimeInterval = 5 * 60
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { TrailerGate.shared.check() }
        }
    }

    /// Any press (`InputHold`): awake again.
    func pressed() {
        if idle { idle = false; trailerLog("a press — trailers again") }
    }

    private func check() {
        // Before the first press, the launch counts as one.
        let still = CACurrentMediaTime() - max(InputHold.lastPress, InputHold.launched)
        if !idle, still >= Self.idleAfter {
            idle = true
            trailerLog("no press for %.0f min — no trailers until one", Self.idleAfter / 60)
        }
    }
}

/// THE TRAILER ON THE BILLBOARD (Home) and Details' picture: resting on a
/// title (`Spotlight.trailerDelay`), its trailer fades in over the picture,
/// in its place, under the shade and text. Anything else — a press,
/// focus off the buttons, leaving — fades it back out to the still; resting again,
/// it goes on where it was (another title: from its start). Played to its
/// end: back to the still, `endings` (the billboard moves on), and that
/// title's trailer doesn't play again this visit.
@MainActor
final class StageTrailer: ObservableObject {
    /// Fading in or playing.
    @Published private(set) var playing = false
    /// On the picture (fading in, or in) — what makes room for it follows
    /// (the peek; Home's dots too).
    @Published private(set) var shown = false
    /// Full screen (Details' Trailer button): the same player, with sound
    /// and the player's controls (`TrailerFullScreen`) — nil while it loads.
    @Published private(set) var full = false
    @Published private(set) var fullPlayer: AVPlayer?
    @Published private(set) var fullFailed = false
    /// The video, wherever the picture is (Home: moved onto the current
    /// card — `StagePictureView.attachTrailer`; Details': its card's).
    let surface = TrailerSurface()
    weak var stage: TrailerHost?
    /// Played to their end: Home follows it, with its state of that moment.
    @Published private(set) var endings = 0

    private var itemID: String?
    private var player: AVPlayer?
    private var youtubeKey: String?
    private var pending: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var readyObserver: NSKeyValueObservation?
    /// For the log (`[CueTrailer]`): how soon it played, stalls, dropped frames.
    private var stallObserver: NSObjectProtocol?
    private var playingObserver: NSKeyValueObservation?
    private var loadedAt = Date()
    private var shownAt: Date?
    private var ended: Set<String> = []
    /// Titles whose trailer has been seen — played `seenAfter` seconds or
    /// `seenShare` of it, whichever first — anywhere (billboard, cards):
    /// not started again for `seenLife` (once played to its end was the
    /// billboard's rule alone). Details doesn't follow it: there you came for
    /// the title.
    private static var seen: [String: Date] = [:]
    private static let seenAfter: Double = 30
    private static let seenShare: Double = 0.5
    private static let seenLife: TimeInterval = 6 * 60 * 60
    private var seenObserver: (player: AVPlayer, token: Any)?
    private static func isSeen(_ titleID: String) -> Bool {
        guard let at = seen[titleID] else { return false }
        if Date().timeIntervalSince(at) < seenLife { return true }
        seen[titleID] = nil
        return false
    }
    /// The rest's title, for one more try when a remembered URL is dead.
    private var request: (item: MetaItem, season: Int?, aired: Date?, sound: Bool)?
    /// The sound rising from silence as it comes in (a showcase card's).
    private var rise = false
    /// Between `rest` and the next `pause` / `stop`.
    private var resting = false
    /// Taken over from the page before (`adopt`), playing, until this page
    /// rests on it: its pauses wait for that.
    private var carriedIn = false
    private var retried: Set<String> = []
    /// The trailer going on into the next page (Home's billboard → Details):
    /// its player, playing, until that page takes it (`adopt`).
    /// `from`: a card's place on screen (the opening grows the video out of it).
    private static var carried: (titleID: String, player: AVPlayer, key: String, from: CGRect?)?
    /// The rest before YouTube is asked (`rest`).
    static let settle: Double = 1
    static let fadeIn: Double = 0.6
    static let fadeOut: Double = 0.35

    /// Resting on `item` (nil: not resting — out, and forgotten); a show's
    /// `season` (an episode of it `aired` then): that season's trailer first.
    /// Resolved and loaded at once, hidden (usually already resolved —
    /// `TrailerResolver.warm`): when the rest's delay is up, the first frame
    /// is there.
    /// `honoursSeen`: false on Details (`seen`).
    func rest(on item: MetaItem?, season: Int? = nil, aired: Date? = nil, sound: Bool, rise: Bool = false,
              honoursSeen: Bool = true) {
        pending?.cancel()
        self.rise = rise
        guard let item else { return stop() }
        let id = item.id + (season.map { "#\($0)" } ?? "")
        // The page before's trailer goes on, whichever season it is.
        if carriedIn, itemID == item.id { itemID = id }
        carriedIn = false
        if id != itemID { stop(); itemID = id }
        guard !ended.contains(id) else { return }
        // Seen: not started again (one paused here goes on).
        if honoursSeen, player == nil, Self.isSeen(item.id) { return }
        request = (item, season, aired, sound)
        resting = true
        pending = Task { [weak self] in
            let begun = Date()
            guard let self else { return }
            if self.player == nil {
                guard !TrailerGate.shared.idle else { return }
                let keys = await TMDBService.trailerKeys(id: item.id, type: item.type,
                                                         season: season, aired: aired)
                guard !Task.isCancelled else { return }
                guard !keys.isEmpty else { return trailerLog("%@: no trailer on TMDB", item.name) }
                // Asked of YouTube only once the rest has settled: focus
                // passing over a card costs nothing (a kept one plays at
                // once).
                if !TrailerResolver.isResolved(keys) {
                    let settle = Self.settle - Date().timeIntervalSince(begun)
                    if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
                    guard !Task.isCancelled else { return }
                    if TrailerResolver.heldOff { return trailerLog("%@: YouTube paused", item.name) }
                }
                guard let found = await TrailerResolver.backdropItem(candidates: keys) else {
                    if !Task.isCancelled { trailerLog("%@: none of %d trailers resolved", item.name, min(keys.count, TrailerResolver.maxCandidates)) }
                    return
                }
                guard !Task.isCancelled, self.itemID == id else { return }
                self.load(found.item, key: found.youtubeKey)
            }
            let left = Spotlight.trailerDelay - Date().timeIntervalSince(begun)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            guard !Task.isCancelled, self.itemID == id, let player = self.player else { return }
            // Idle by now: a fresh one doesn't start (one paused goes on).
            if TrailerGate.shared.idle, player.currentTime().seconds < 1 { return }
            self.setSound(sound && !rise)
            self.show(player)
            if sound && rise {
                player.volume = 0
                player.isMuted = false
                self.fadeSound(to: 1, over: Self.soundRise)
            }
        }
    }

    /// Back to the still, the trailer kept where it is.
    func pause() {
        guard !carriedIn, !full else { return }
        resting = false
        pending?.cancel()
        player?.pause()
        fade(to: 0)
    }

    /// Back to the still, the trailer let go.
    func stop() {
        carriedIn = false
        resting = false
        pending?.cancel()
        itemID = nil
        release()
    }

    /// The end of a visit: every title's trailer may play again.
    func reset() {
        stop()
        ended = []
        retried = []
    }

    /// Into Details, or back out of it to Home: the trailer, if it's
    /// playing, handed on (`adopt`) rather than stopped — this page lets go
    /// of it. Nil: none playing. Not taken `within` that long (the opening
    /// didn't happen, no billboard on that title): let go.
    @discardableResult
    func handOver(within wait: Double = 5, from card: CGRect? = nil) -> AVPlayer? {
        guard playing, let player, let key = youtubeKey, let id = itemID else { return nil }
        let titleID = String(id.split(separator: "#", maxSplits: 1).first ?? "")
        Self.carried = (titleID, player, key, card)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard Self.carried?.player === player else { return }
            Self.carried = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        resting = false
        pending?.cancel()
        itemID = nil
        dropObservers()
        self.player = nil
        youtubeKey = nil
        playing = false
        return player
    }

    /// The trailer the page before handed on (`handOver`), if it's
    /// `item`'s: on at once, where it was — no delay, no fade.
    func adopt(_ item: MetaItem) {
        guard let carried = Self.carried, carried.titleID == item.id else { return }
        Self.carried = nil
        stop()
        itemID = item.id
        carriedIn = true
        watch(carried.player, key: carried.key)
        watchSeen(carried.player)
        shownAt = Date()
        playingObserver = nil
        stage?.attachTrailer(surface)
        surface.player = carried.player
        surface.alpha = 1
        playing = true
        shown = true
    }

    /// The player handed over for `titleID`, if it is (the opening plays it on).
    static func carried(for titleID: String) -> AVPlayer? { carried?.titleID == titleID ? carried?.player : nil }
    /// The card it was handed over from, on screen (nil: the billboard's).
    static func carriedFrame(for titleID: String) -> CGRect? { carried?.titleID == titleID ? carried?.from : nil }

    /// The title whose trailer is playing (nil: none).
    var playingTitle: String? {
        guard playing, let itemID else { return nil }
        return String(itemID.split(separator: "#", maxSplits: 1).first ?? "")
    }
    /// One handed over, not yet taken (Back from Details: Home's billboard).
    static var carrying: Bool { carried != nil }

    /// Full screen: the trailer on the picture, if there's one (where it
    /// is), else `item`'s from its start.
    func playFull(on item: MetaItem, season: Int?, aired: Date?) {
        full = true
        fullFailed = false
        resting = false
        pending?.cancel()
        if let player { return goFull(player) }
        let id = item.id + (season.map { "#\($0)" } ?? "")
        stop()
        itemID = id
        ended.remove(id)
        pending = Task { [weak self] in
            let keys = await TMDBService.trailerKeys(id: item.id, type: item.type, season: season, aired: aired)
            let found = keys.isEmpty ? nil : await TrailerResolver.backdropItem(candidates: keys)
            guard let self, !Task.isCancelled, self.full, self.itemID == id else { return }
            guard let found else { self.fullFailed = true; return }
            self.load(found.item, key: found.youtubeKey)
            if let player = self.player { self.goFull(player) }
        }
    }

    /// Out of full screen: on the picture again, with its own sound —
    /// playing on if the page rests on it (its pauses wait for that).
    func leaveFull(resting: Bool, sound: Bool) {
        guard full else { return }
        full = false
        fullPlayer = nil
        pending?.cancel()
        guard player != nil else { return }
        // The sound back to the page's: without, it falls away as the text
        // comes back.
        if sound { setSound(true) } else { fadeSound(to: 0, over: Motion.presentDuration) { $0.isMuted = true; $0.volume = 1 } }
        if resting { carriedIn = true } else { pause() }
    }

    private func goFull(_ player: AVPlayer) {
        // The sound rises from where it was (silent on the page: from nothing).
        if player.isMuted {
            player.volume = 0
            player.isMuted = false
        }
        fadeSound(to: 1, over: Self.soundRise)
        fullPlayer = player
        // On the picture too, for after.
        show(player)
    }

    /// Full screen's sound rising from silence (as the player's start).
    private static let soundRise: Double = 0.8
    private var soundFade: Timer?

    /// On or off at once, a fade under way dropped.
    private func setSound(_ on: Bool) {
        soundFade?.invalidate()
        soundFade = nil
        player?.volume = 1
        player?.isMuted = !on
    }

    /// The volume to `target` evenly over `seconds`; `done` once there, if
    /// it's still this page's player.
    private func fadeSound(to target: Float, over seconds: Double, done: ((AVPlayer) -> Void)? = nil) {
        soundFade?.invalidate()
        guard let player else { return }
        let id = ObjectIdentifier(player)
        let from = player.volume
        let began = CACurrentMediaTime()
        soundFade = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, ObjectIdentifier(player) == id else { return timer.invalidate() }
                let progress = min(1, (CACurrentMediaTime() - began) / seconds)
                player.volume = from + (target - from) * Float(progress)
                guard progress >= 1 else { return }
                timer.invalidate()
                self.soundFade = nil
                done?(player)
            }
        }
    }

    /// The player, loading behind the picture (not playing yet).
    private func load(_ item: AVPlayerItem, key: String) {
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // Waiting, always: not waiting, one played with little in its buffer
        // (fetched just as the rest ended: the cards' usual case) stalled at
        // its first frame and never went on — on the card, in Details that
        // took it over; only full screen, which set this, played it.
        player.automaticallyWaitsToMinimizeStalling = true
        // Not the system's Now Playing (it's the page's picture).
        player.allowsExternalPlayback = false
        watch(player, key: key)
        stage?.attachTrailer(surface)
        surface.player = player
    }

    /// This page's player from now on: its end, failure and the log.
    private func watch(_ player: AVPlayer, key: String) {
        guard let item = player.currentItem else { return }
        self.player = player
        youtubeKey = key
        loadedAt = Date()
        shownAt = nil
        let id = itemID
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let shown = self.shownAt else { return }
                trailerLog("%@: stalled %.1f s in", key, Date().timeIntervalSince(shown))
            }
        }
        playingObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            DispatchQueue.main.async {
                guard let self, self.player === player, let shown = self.shownAt,
                      self.playingObserver != nil else { return }
                self.playingObserver = nil
                trailerLog("%@: playing %.2f s after the delay (loading began %.2f s before it)",
                      key, Date().timeIntervalSince(shown), shown.timeIntervalSince(self.loadedAt))
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // By the player: taken over, its title's id gains the season.
                guard let self, self.player === player else { return }
                if let id = self.itemID { self.ended.insert(id) }
                self.full = false
                self.release()
                self.endings &+= 1
            }
        }
        readyObserver = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            trailerLog("%@: failed — %@", key, String(describing: item.error))
            DispatchQueue.main.async {
                guard let self, self.player === player, let id else { return }
                if let key = self.youtubeKey { TrailerResolver.invalidate(youtubeKey: key) }
                self.release()
                if self.full { self.fullFailed = true }
                // A remembered URL gone dead (expired early, another address):
                // resolved again, once.
                if !self.retried.contains(id), let request = self.request {
                    self.retried.insert(id)
                    if self.resting {
                        self.itemID = nil
                        self.rest(on: request.item, season: request.season, aired: request.aired,
                                  sound: request.sound)
                    }
                } else {
                    self.ended.insert(id)
                }
            }
        }
    }

    /// Counts its title seen once played far enough (`seen`).
    private func watchSeen(_ player: AVPlayer) {
        guard seenObserver?.player !== player, let id = itemID else { return }
        dropSeen()
        let titleID = String(id.split(separator: "#", maxSplits: 1).first ?? "")
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                                                   queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = player.currentItem else { return }
                let length = item.duration.seconds
                let mark = length.isFinite && length > 0 ? min(Self.seenAfter, length * Self.seenShare) : Self.seenAfter
                guard time.seconds >= mark else { return }
                if !Self.isSeen(titleID) { trailerLog("%@: seen (%.0f s)", self.youtubeKey ?? "?", time.seconds) }
                Self.seen[titleID] = Date()
                self.dropSeen()
            }
        }
        seenObserver = (player, token)
    }

    private func dropSeen() {
        if let seenObserver { seenObserver.player.removeTimeObserver(seenObserver.token) }
        seenObserver = nil
    }

    /// Plays, fading in once a frame is up.
    private func show(_ player: AVPlayer) {
        watchSeen(player)
        stage?.attachTrailer(surface)
        surface.player = player
        if shownAt == nil { shownAt = Date() }
        player.play()
        playing = true
        // In once a frame is up AND it moves: a frame alone, still
        // buffering, read as a frozen trailer.
        surface.whenReady { [weak self] in
            guard let self, self.player === player, self.playing else { return }
            if player.timeControlStatus == .playing { return self.fade(to: 1) }
            self.movingObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
                guard player.timeControlStatus == .playing else { return }
                DispatchQueue.main.async {
                    guard let self, self.player === player, self.playing else { return }
                    self.movingObserver = nil
                    self.fade(to: 1)
                }
            }
        }
    }
    private var movingObserver: NSKeyValueObservation?

    private func dropObservers() {
        dropSeen()
        movingObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        endObserver = nil
        stallObserver = nil
        readyObserver = nil
        playingObserver = nil
    }

    private func release() {
        dropObservers()
        guard let player else { return fade(to: 0) }
        if shownAt != nil, let item = player.currentItem, let events = item.accessLog()?.events, !events.isEmpty {
            trailerLog("%@: let go — %dp, %.1f of %.1f Mbps, %d stalls, %d frames dropped",
                  youtubeKey ?? "?", Int(item.presentationSize.height),
                  (events.last?.observedBitrate ?? 0) / 1e6, (events.last?.indicatedBitrate ?? 0) / 1e6,
                  events.reduce(0) { $0 + $1.numberOfStalls },
                  events.reduce(0) { $0 + $1.numberOfDroppedVideoFrames })
        }
        self.player = nil
        youtubeKey = nil
        fullPlayer = nil
        player.pause()
        fade(to: 0) { [weak self] in
            if self?.player == nil { self?.surface.player = nil }
            player.replaceCurrentItem(with: nil)
        }
    }

    private func fade(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        if alpha == 0 { playing = false }
        if shown != (alpha > 0) { shown = alpha > 0 }
        stage?.trailerShown(alpha > 0)
        let view = surface
        guard view.alpha != alpha else { completion?(); return }
        UIView.animate(withDuration: alpha > 0 ? Self.fadeIn : Self.fadeOut, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]) {
            view.alpha = alpha
        } completion: { _ in completion?() }
    }
}

/// Where a `StageTrailer` plays: Home's and Details' picture
/// (`StagePictureView`), a showcase card (`FixedFocusShowcaseCell`).
@MainActor
protocol TrailerHost: AnyObject {
    func attachTrailer(_ surface: TrailerSurface)
    /// The trailer coming in (fading in) or going.
    func trailerShown(_ shown: Bool)
}

extension TrailerHost {
    func trailerShown(_ shown: Bool) {}
}

/// The trailer's video: fills its frame as the picture does.
final class TrailerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var readyObserver: NSKeyValueObservation?

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Once a frame is up (at once if it is).
    func whenReady(_ action: @escaping @MainActor () -> Void) {
        readyObserver = nil
        if playerLayer.isReadyForDisplay { return action() }
        readyObserver = playerLayer.observe(\.isReadyForDisplay) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                self?.readyObserver = nil
                action()
            }
        }
    }
}

/// Details' trailer full screen: the player's controls over Details' own
/// picture, where the trailer plays (`TrailerController`) — the page's text
/// fades out under it (`DetailView`); Back closes it, the trailer playing on.
struct TrailerFullScreen: View {
    @ObservedObject var trailer: StageTrailer
    /// The title's name over the bar.
    let title: String
    let close: () -> Void

    var body: some View {
        ZStack {
            if let player = trailer.fullPlayer {
                TrailerControls(player: player, title: title, close: close).ignoresSafeArea()
            } else if trailer.fullFailed {
                Color.black.opacity(0.6).ignoresSafeArea()
                CueEmptyState(icon: "play.slash.fill", title: "Trailer unavailable",
                              message: "This trailer couldn't be loaded. Press Menu to go back.")
                    .onExitCommand(perform: close)
            } else {
                CueLoadingView(label: "Loading trailer")
                    .onExitCommand(perform: close)
            }
        }
        // Not over the controls: SwiftUI's took Back before `TrailerController`.
        .interactiveDismissDisabled()
        // On the picture: dark in both appearances. SwiftUI hands its own
        // scheme down to the controller, past its `overrideUserInterfaceStyle`.
        .environment(\.colorScheme, .dark)
    }
}

private struct TrailerControls: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let close: () -> Void

    func makeUIViewController(context: Context) -> TrailerController {
        TrailerController(player: player, title: title, close: close)
    }
    func updateUIViewController(_ controller: TrailerController, context: Context) {
        controller.close = close
    }
    static func dismantleUIViewController(_ controller: TrailerController, coordinator: ()) {
        controller.teardown()
    }
}

/// The player's bar and its presses (`PlayerTransport`, `PlayerOverlay`) on a
/// trailer: the title's name over it, no buttons, no shelf, no stills. Every
/// press brings the controls up; with them up Up puts them away and Down
/// closes (the hint where the shelf would peek says so). Back hides them,
/// then closes; for 1 s after they hide by themselves Back and Down do nothing.
final class TrailerController: UIViewController, UIGestureRecognizerDelegate, TransportMedia {
    var close: () -> Void
    private let player: AVPlayer
    private let focusView = PlayerFocusView()
    private let overlay: PlayerOverlay
    private let transport: PlayerTransport
    private var timer: Timer?
    private let hint = TrailerDownHint()

    init(player: AVPlayer, title: String, close: @escaping () -> Void) {
        self.player = player
        self.close = close
        overlay = PlayerOverlay(title: title, episode: nil)
        transport = PlayerTransport(overlay: overlay)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [focusView] }

    override func viewDidLoad() {
        super.viewDidLoad()
        // On pictures or glass: dark in both appearances (`CueInk`).
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        for sub in [focusView, overlay, hint] as [UIView] { view.addSubview(sub) }
        transport.media = self
        overlay.setBarFocused(true)

        let back = UITapGestureRecognizer(target: self, action: #selector(backPressed))
        back.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(back)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for sub in [focusView, overlay] as [UIView] { sub.frame = view.bounds }
        // Where the shelf's tabs peek in the player: the words in line with the bar.
        let size = hint.intrinsicContentSize
        hint.bounds = CGRect(origin: .zero, size: size)
        hint.center = CGPoint(x: TrailerDownHint.inset + size.width / 2,
                              y: view.bounds.height - TrailerDownHint.fromFoot)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        transport.end()
        transport.stop()
    }

    // MARK: TransportMedia

    var duration: Double {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }
    var position: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }
    var isPaused: Bool { player.timeControlStatus == .paused }
    func play() { player.play() }
    func pause() { player.pause() }
    func togglePlayPause() { isPaused ? play() : pause() }
    func seek(to seconds: Double) async {
        await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else { return }
        // Back is `backPressed`'s: here it would bring the controls back up.
        guard press.type != .menu else { return super.pressesBegan(presses, with: event) }
        switch press.type {
        case .upArrow, .downArrow:
            // Down closes, the controls up or not (bringing them up first
            // was a press too many); Up puts them away, gone brings them up.
            // Scrubbing or in the scan, both only keep them up.
            let scrubbing = transport.isScrubbing
            if press.type == .downArrow, !scrubbing {
                return leave()
            } else if press.type == .upArrow, overlay.isShown, !scrubbing {
                transport.dismiss()
            } else {
                transport.wake()
            }
            return tick()
        default:
            if transport.press(press.type) { return tick() }
            transport.wake()
            tick()
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        transport.endHold(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        transport.endHold(presses)
        super.pressesCancelled(presses, with: event)
    }

    /// A recognizer, as the player's: handed on, Back reached the cover, which closed.
    @objc private func backPressed() {
        if transport.back() {
            tick()
        } else if overlay.isShown {
            transport.dismiss()
            tick()
        } else if !transport.inBackGrace {
            leave()
        }
    }

    /// Closing pauses the trailer (unless it rests on the card): the tick
    /// stops first, or it would bring the controls up for the pause.
    private func leave() {
        timer?.invalidate()
        timer = nil
        close()
    }

    /// Paused, a sideways swipe scrubs; nothing else does anything.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return transport.isFine && abs(velocity.x) > abs(velocity.y)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        transport.pan(pan, in: view)
    }

    // MARK: Screen

    private func tick() {
        transport.tick()
        let duration = duration
        overlay.update(time: transport.time, duration: duration, mark: transport.mark,
                       waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        let loaded = player.currentItem?.loadedTimeRanges.map(\.timeRangeValue).compactMap { range -> ClosedRange<Double>? in
            let (from, to) = (range.start.seconds, range.end.seconds)
            return from.isFinite && to.isFinite && to >= from ? from...to : nil
        } ?? []
        overlay.setHeld(loaded, duration: duration)
        let shown = transport.target != nil || transport.wantsShown
        transport.noteShown(shown, byThemselves: true)
        if shown != overlay.isShown {
            // Gone, they rest a little lower, as the player's.
            overlay.setShift(shown ? 0 : TrailerDownHint.drop)
            hint.move(shown: shown)
        }
        overlay.setShown(shown)
        overlay.setScrubbing(transport.isScrubbing, detached: transport.isDetached)
        hint.setAway(transport.target != nil && transport.isDetached)
    }
}

/// In the shelf's place: a chevron and "Back to Details", the tabs' words
/// at rest (26 pt medium, the body level, their shadow); Down closes. With
/// the controls, gone in the scan and paused scrubbing as the peek is.
private final class TrailerDownHint: UIView {
    /// The bar's inset: the words line up with it, as the peek's.
    static let inset: CGFloat = 80
    /// The tab row's middle, measured from the screen's foot (the peek).
    static let fromFoot: CGFloat = 52
    /// How much lower it and the controls rest while gone.
    static let drop: CGFloat = 24
    private static let gap: CGFloat = 12

    private let chevron = UIImageView()
    private let label = UILabel()
    private var shown = false
    private var away = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: Self.drop)
        let color = CueInk.ui(FixedFocusText.body)
        chevron.image = UIImage(systemName: "chevron.down",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        chevron.tintColor = color
        chevron.contentMode = .center
        label.text = "Back to Details"
        label.font = .systemFont(ofSize: 26, weight: .medium)
        label.textColor = color
        for sub in [chevron, label] as [UIView] {
            sub.layer.shadowColor = UIColor.black.cgColor
            sub.layer.shadowOffset = .zero
            sub.layer.shadowRadius = 8
            sub.layer.shadowOpacity = 0.8
            addSubview(sub)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let text = label.intrinsicContentSize
        let mark = chevron.intrinsicContentSize
        return CGSize(width: mark.width + Self.gap + text.width, height: max(text.height, mark.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let mark = chevron.intrinsicContentSize
        chevron.frame = CGRect(x: 0, y: 0, width: mark.width, height: bounds.height)
        label.frame = CGRect(x: mark.width + Self.gap, y: 0,
                             width: bounds.width - mark.width - Self.gap, height: bounds.height)
    }

    /// With the controls: a fade and the same short way up or down.
    func move(shown: Bool) {
        self.shown = shown
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.transform = shown ? .identity : CGAffineTransform(translationX: 0, y: Self.drop)
        }
        fade()
    }

    func setAway(_ away: Bool) {
        guard away != self.away else { return }
        self.away = away
        fade()
    }

    private func fade() {
        let alpha: CGFloat = shown && !away ? 1 : 0
        guard alpha != self.alpha else { return }
        UIView.animate(withDuration: Motion.fadeDuration) { self.alpha = alpha }
    }
}

