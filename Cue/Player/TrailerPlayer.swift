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
    /// Bounded because every miss costs a full extraction (5: a cut below
    /// `minimumHeight` counts as a miss too).
    static let maxCandidates = 5

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
        do {
            let youtube = YouTube(videoID: youtubeKey, methods: [.local])
            let streams = try await youtube.streams
            // The same answer carries the HLS manifest (no request of its own).
            let hls = try? await youtube.livestreams.first?.url
            if !streams.isEmpty { return (streams, hls) }
            NSLog("[CueTrailer] local extraction returned nothing for %@ — trying remote", youtubeKey)
        } catch {
            // Age-restricted: the remote extractor spends ~10 s and fails too.
            if String(describing: error).contains("AgeRestricted") {
                refuse(youtubeKey: youtubeKey, reason: "age restricted")
                return nil
            }
            // The remote extractor asks from this address too: no use.
            if (error as? YouTubeKitError) == .botCheck {
                holdOff("YouTube's bot check")
                return nil
            }
            if (error as? YouTubeKitError) == .regexMatchError {
                NSLog("[CueTrailer] YouTube's page unreadable for %@ — refused", youtubeKey)
                return nil
            }
            NSLog("[CueTrailer] local extraction failed for %@: %@ — trying remote",
                  youtubeKey, String(describing: error))
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
            NSLog("[CueTrailer] extraction failed for %@: %@", youtubeKey, String(describing: error))
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
            NSLog("[CueTrailer] %@: HLS manifest unreadable", key)
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
            NSLog("[CueTrailer] %@: HLS has nothing good enough (%d variants)", key, total)
            return nil
        }
        NSLog("[CueTrailer] %@: HLS up to %dp, %d of %d variants (%@)", key, height,
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
        return AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]
        ])
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
            NSLog("[CueTrailer] merge failed: %@", String(describing: error))
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
    }
    private struct Stored: Codable {
        var choices: [String: BackdropChoice] = [:]
        var refused: [String: Refusal] = [:]
    }
    private static let refusalTTL: TimeInterval = 30 * 24 * 60 * 60
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
        value.refused = value.refused.filter { now.timeIntervalSince($0.value.at) < refusalTTL }
        return value
    }()
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
    /// rest on the same title). Not cancelled with an asker: what it finds
    /// is kept for the next.
    private static var resolving: [String: Task<BackdropChoice?, Never>] = [:]

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
        NSLog("[CueTrailer] network path changed — dropped the resolved-URL cache")
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

    /// YouTube's "confirm you're not a bot" (it flags an address that asks
    /// too much — the warm-up, every launch), or `failuresAllowed` keys in a
    /// row not resolving (its watch page refused too): no trailer resolved
    /// for `holdOffPause` — every request would only keep the flag on.
    private static func holdOff(_ reason: String) {
        let first = backdropCacheLock.withLock {
            defer { heldOffUntil = Date().addingTimeInterval(holdOffPause); failuresInARow = 0 }
            return heldOffUntil.map { $0 < Date() } ?? true
        }
        if first { NSLog("[CueTrailer] %@ — no trailers for %d min", reason, Int(holdOffPause / 60)) }
    }
    /// Kept in the defaults: a relaunch (or a new build) mustn't start
    /// asking again at once.
    private static var heldOffUntil: Date? {
        get { UserDefaults.standard.object(forKey: "cue.trailers.heldOffUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "cue.trailers.heldOffUntil") }
    }
    private static let holdOffPause: TimeInterval = 30 * 60
    private static var failuresInARow = 0
    private static let failuresAllowed = 3

    /// A key extracted or not (a cancelled one doesn't count).
    private static func noteExtraction(ok: Bool) {
        guard !Task.isCancelled else { return }
        let tooMany = backdropCacheLock.withLock {
            failuresInARow = ok ? 0 : failuresInARow + 1
            return failuresInARow >= failuresAllowed
        }
        if tooMany { holdOff("\(failuresAllowed) trailers in a row not resolving") }
    }

    /// Remember that a key will never do (for `refusalTTL`).
    private static func refuse(youtubeKey: String, reason: String) {
        NSLog("[CueTrailer] %@: %@ — not used", youtubeKey, reason)
        backdropCacheLock.withLock {
            stored.refused[youtubeKey] = Refusal(reason: reason, at: Date())
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
    static func backdropItem(candidates: [String]) async -> (item: AVPlayerItem, youtubeKey: String)? {
        for key in candidates.prefix(maxCandidates) {
            guard !Task.isCancelled else { return nil }
            if let choice = await choice(youtubeKey: key), !Task.isCancelled,
               let item = await backdropPlayerItem(choice, key: key) {
                return (item, key)
            }
        }
        return nil
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
               Date().timeIntervalSince(refused.at) < refusalTTL { return nil }
            if let failed = backdropFailureCache[youtubeKey],
               Date().timeIntervalSince(failed.at) < backdropFailureTTL { return nil }
            if let until = heldOffUntil, until > Date() { return nil }
            if let running = resolving[youtubeKey] { return running }
            let task = Task.detached(priority: .userInitiated) { () -> BackdropChoice? in
                let choice = await extractChoice(youtubeKey: youtubeKey, generation: generation)
                backdropCacheLock.withLock { resolving[youtubeKey] = nil }
                return choice
            }
            resolving[youtubeKey] = task
            return task
        }
        return await task?.value
    }

    private static func extractChoice(youtubeKey: String, generation: UInt64) async -> BackdropChoice? {
        guard let found = await extractStreams(youtubeKey: youtubeKey) else {
            rememberFailure(youtubeKey: youtubeKey, generation: generation)
            noteExtraction(ok: false)
            return nil
        }
        noteExtraction(ok: true)
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
        NSLog("[CueTrailer] backdrop %@: %dp (%@)", youtubeKey, choice.height,
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
            NSLog("[CueTrailer] backdrop merge failed — falling back to the muxed stream")
            return budgeted(AVPlayerItem(asset: asset(for: fallback)))
        }
        return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
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
}

/// THE TRAILER ON THE BILLBOARD (Home) and Details' picture: resting on a
/// title (`Spotlight.trailerDelay`), its trailer fades in over the picture,
/// in its place, under the shade and text. Anything else — a press,
/// focus off the buttons, leaving — fades it back out to the still; resting again,
/// it goes on where it was (another title: from its start). Played to its
/// end: back to the still, `onEnd` (the billboard moves on), and that
/// title's trailer doesn't play again this visit.
@MainActor
final class StageTrailer: ObservableObject {
    /// Fading in or playing.
    @Published private(set) var playing = false
    /// On the picture (fading in, or in) — what makes room for it follows
    /// (the peek; Home's dots too).
    @Published private(set) var shown = false
    /// Full screen (Details' Trailer button): the same player, with sound
    /// and the system's controls (`TrailerFullScreen`) — nil while it loads.
    @Published private(set) var full = false
    @Published private(set) var fullPlayer: AVPlayer?
    @Published private(set) var fullFailed = false
    /// The video, wherever the picture is (Home: moved onto the current
    /// card — `StagePictureView.attachTrailer`; Details: `StageTrailerView`).
    let surface = TrailerSurface()
    weak var stage: StagePictureView?
    var onEnd: (() -> Void)?

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
    /// The rest's title, for one more try when a remembered URL is dead.
    private var request: (item: MetaItem, season: Int?, aired: Date?, sound: Bool)?
    /// Between `rest` and the next `pause` / `stop`.
    private var resting = false
    /// Taken over from the page before (`adopt`), playing, until this page
    /// rests on it: its pauses wait for that.
    private var carriedIn = false
    private var retried: Set<String> = []
    /// The trailer going on into the next page (Home's billboard → Details):
    /// its player, playing, until that page takes it (`adopt`).
    private static var carried: (titleID: String, player: AVPlayer, key: String)?
    static let fadeIn: Double = 0.6
    /// Settings → Appearance (trying): the peek and the dots move out the
    /// bottom while a trailer plays, instead of fading.
    static let peekMovesKey = "cue.trailer.peekMovesOut"
    static var peekMovesOut: Bool { UserDefaults.standard.bool(forKey: peekMovesKey) }
    static let fadeOut: Double = 0.35

    /// Resting on `item` (nil: not resting — out, and forgotten); a show's
    /// `season` (an episode of it `aired` then): that season's trailer first.
    /// Resolved and loaded at once, hidden (usually already resolved —
    /// `TrailerResolver.warm`): when the rest's delay is up, the first frame
    /// is there.
    func rest(on item: MetaItem?, season: Int? = nil, aired: Date? = nil, sound: Bool) {
        pending?.cancel()
        guard let item, !UIAccessibility.isReduceMotionEnabled else { return stop() }
        let id = item.id + (season.map { "#\($0)" } ?? "")
        // The page before's trailer goes on, whichever season it is.
        if carriedIn, itemID == item.id { itemID = id }
        carriedIn = false
        if id != itemID { stop(); itemID = id }
        guard !ended.contains(id) else { return }
        request = (item, season, aired, sound)
        resting = true
        pending = Task { [weak self] in
            let begun = Date()
            guard let self else { return }
            if self.player == nil {
                let keys = await TMDBService.trailerKeys(id: item.id, type: item.type,
                                                         season: season, aired: aired)
                guard !Task.isCancelled, !keys.isEmpty,
                      let found = await TrailerResolver.backdropItem(candidates: keys),
                      !Task.isCancelled, self.itemID == id else { return }
                self.load(found.item, key: found.youtubeKey)
            }
            let left = Spotlight.trailerDelay - Date().timeIntervalSince(begun)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            guard !Task.isCancelled, self.itemID == id, let player = self.player else { return }
            player.isMuted = !sound
            self.show(player)
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
    func handOver(within wait: Double = 5) -> AVPlayer? {
        guard playing, let player, let key = youtubeKey, let id = itemID else { return nil }
        let titleID = String(id.split(separator: "#", maxSplits: 1).first ?? "")
        Self.carried = (titleID, player, key)
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
        shownAt = Date()
        playingObserver = nil
        stage?.attachTrailer(surface)
        surface.player = carried.player
        surface.alpha = 1
        playing = true
        shown = true
    }

    /// Home handed over `titleID`'s trailer (Details opening on it takes it).
    static func carries(_ titleID: String) -> Bool { carried?.titleID == titleID }

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
        guard let player else { return }
        player.isMuted = !sound
        if resting { carriedIn = true } else { pause() }
    }

    private func goFull(_ player: AVPlayer) {
        player.isMuted = false
        fullPlayer = player
        // On the picture too, for after.
        show(player)
    }

    /// The player, loading behind the picture (not playing yet).
    private func load(_ item: AVPlayerItem, key: String) {
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
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
                NSLog("[CueTrailer] %@: stalled %.1f s in", key, Date().timeIntervalSince(shown))
            }
        }
        playingObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            DispatchQueue.main.async {
                guard let self, self.player === player, let shown = self.shownAt,
                      self.playingObserver != nil else { return }
                self.playingObserver = nil
                NSLog("[CueTrailer] %@: playing %.2f s after the delay (loading began %.2f s before it)",
                      key, Date().timeIntervalSince(shown), shown.timeIntervalSince(self.loadedAt))
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.itemID == id else { return }
                if let id { self.ended.insert(id) }
                self.full = false
                self.release()
                self.onEnd?()
            }
        }
        readyObserver = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            NSLog("[CueTrailer] %@: failed — %@", key, String(describing: item.error))
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

    /// Plays, fading in once a frame is up.
    private func show(_ player: AVPlayer) {
        stage?.attachTrailer(surface)
        surface.player = player
        if shownAt == nil { shownAt = Date() }
        player.play()
        playing = true
        surface.whenReady { [weak self] in
            guard let self, self.player === player, self.playing else { return }
            self.fade(to: 1)
        }
    }

    private func dropObservers() {
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
            NSLog("[CueTrailer] %@: let go — %dp, %.1f of %.1f Mbps, %d stalls, %d frames dropped",
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

    /// The billboard paged with the peek moved out: it comes back at the
    /// press, with the slide — this trailer's stop follows a few frames on.
    func letPeekBack() { if shown { shown = false } }

    private func fade(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        if alpha == 0 { playing = false }
        if shown != (alpha > 0) { shown = alpha > 0 }
        let view = surface
        guard view.alpha != alpha else { completion?(); return }
        UIView.animate(withDuration: alpha > 0 ? Self.fadeIn : Self.fadeOut, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]) {
            view.alpha = alpha
        } completion: { _ in completion?() }
    }
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

/// Details' trailer full screen: its player with the system's controls
/// (pause, scrubbing); Back closes it, the trailer playing on behind.
struct TrailerFullScreen: View {
    @ObservedObject var trailer: StageTrailer
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = trailer.fullPlayer {
                TrailerControls(player: player).ignoresSafeArea()
            } else if trailer.fullFailed {
                CueEmptyState(icon: "play.slash.fill", title: "Trailer unavailable",
                              message: "This trailer couldn't be loaded. Press Menu to go back.")
            } else {
                CueLoadingView(label: "Loading trailer")
            }
        }
        .onExitCommand(perform: close)
    }
}

private struct TrailerControls: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}

/// Details' trailer: the surface, where its picture is.
struct StageTrailerView: UIViewRepresentable {
    let trailer: StageTrailer
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        host.addSubview(trailer.surface)
        trailer.surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return host
    }
    func updateUIView(_ view: UIView, context: Context) {
        trailer.surface.frame = view.bounds
    }
}
