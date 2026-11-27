import SwiftUI
import UIKit
import CryptoKit
import ImageIO
import CoreImage

// MARK: - Image cache

/// How many pictures decode at once, and in what order. A decode is tens
/// of milliseconds of CPU; unlimited, a held Left/Right started dozens
/// together, frames dropped below 30 and the box's own picture waited
/// behind titles long passed. Three at a time; what's on screen (`now`)
/// always goes first and has one slot to itself, decoding ahead (`ahead`)
/// takes at most two, the newest wish first (the oldest are the ones
/// focus has left).
actor DecodeGate {
    static let shared = DecodeGate()
    enum Turn { case now, ahead }

    private let limit = 3
    private let aheadLimit = 2
    private var running = 0
    private var runningAhead = 0
    private var waitingNow: [CheckedContinuation<Void, Never>] = []
    private var waitingAhead: [CheckedContinuation<Void, Never>] = []

    func enter(_ turn: Turn) async {
        switch turn {
        case .now:
            if running < limit { running += 1; return }
            await withCheckedContinuation { waitingNow.append($0) }
        case .ahead:
            if running < limit, runningAhead < aheadLimit { running += 1; runningAhead += 1; return }
            await withCheckedContinuation { waitingAhead.append($0) }
        }
    }

    func leave(_ turn: Turn) {
        running -= 1
        if turn == .ahead { runningAhead -= 1 }
        if !waitingNow.isEmpty {
            running += 1
            waitingNow.removeFirst().resume()
        } else if !waitingAhead.isEmpty, runningAhead < aheadLimit {
            running += 1; runningAhead += 1
            waitingAhead.removeLast().resume()
        }
    }

    /// `work` in its turn; nil, without running it, when `still` says by
    /// then it's no longer wanted (focus moved on).
    func run<T>(_ turn: Turn, still: (@MainActor () -> Bool)? = nil,
                _ work: @escaping @Sendable () -> T?) async -> T? {
        await enter(turn)
        if let still, !(await still()) { leave(turn); return nil }
        let result = await Task.detached(priority: turn == .now ? .userInitiated : .utility) { work() }.value
        leave(turn)
        return result
    }
}

/// Process-wide image cache with two layers:
///
/// * **Memory** (`NSCache`) — decoded pixels, instant re-show. `AsyncImage`
///   re-downloads and re-decodes every time its view is recreated (which the
///   home hero does on every focus move) — that was the backdrop flicker.
/// * **Disk** (`Caches/cue-images`) — the original encoded bytes, so posters
///   and backdrops survive an app relaunch and don't have to be refetched.
///   LRU-trimmed to a byte budget on launch.
///
/// Memory lookups are synchronous; disk lookups are async (off the main
/// thread) and promote hits back into the memory layer.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// Dedicated download session for artwork. Posters/backdrops nearly all come
    /// from one host (image.tmdb.org), so the default 6-connections-per-host cap
    /// throttles a full poster grid to 6 at a time — raise it so the grid fills
    /// in far fewer round-trips. Own URLCache keeps HTTP-cached art off the
    /// shared session.
    static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = PerformanceProfile.isLowPower ? 6 : (PerformanceProfile.isMidPower ? 8 : 12)
        config.timeoutIntervalForRequest = 25
        // NO URLCache: every body fetched here is persisted (and served back)
        // by ImageCache's own cue-images disk layer, so a URLCache stored
        // each poster a SECOND time — up to 128 MB of duplicate encoded bytes
        // on flash plus 16 MB of cache memory the 2 GB box can't spare.
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private let memory = NSCache<NSString, UIImage>()
    /// What the memory cache holds now, in bytes (the census, Settings).
    var memoryCost: Int { costs.total }
    /// Pictures in memory at more than one size, and the smaller copies' bytes.
    var duplicates: (pictures: Int, bytes: Int) { costs.duplicates() }
    var duplicateSizes: [String] { costs.duplicateSizes() }
    /// A memory key's picture: the key without its size (`#…`).
    nonisolated static func url(ofKey key: String) -> String {
        key.lastIndex(of: "#").map { String(key[..<$0]) } ?? key
    }
    private let costs = CostLedger()
    /// CONCURRENT and user-initiated. As a serial `.utility` queue this made
    /// the best-cached path the slowest one: every newly visible poster queued
    /// behind every other one, single file, at background priority, while the
    /// network path hopped to `.userInitiated` and overtook it. A screenful of
    /// already-cached art cost hundreds of milliseconds of placeholders over
    /// bytes sitting on local disk.
    ///
    /// Reads and writes are independent (distinct files, and a failed read just
    /// re-downloads), so the only ordering that ever mattered is that a clear or
    /// a trim not run alongside them — those use `.barrier`.
    private let ioQueue = DispatchQueue(label: "cue.imagecache.io",
                                        qos: .userInitiated, attributes: .concurrent)
    private let fm = FileManager.default
    private let diskURL: URL
    /// Encoded pictures on disk: Home's (`protectHome`) up to 2 GB, the
    /// rest (Details, pages, the player) 1 GB, oldest out first; in all a
    /// tenth of the free space when that's less, 768 MB at least. Home's
    /// worst case is ~1.2 GB (~1.9 with heavy files); one Details page
    /// 5–75 MB. One budget for both let an evening of Details push out
    /// Home's pictures, the oldest (written at launch): empty cards, the
    /// network again. 512 MB was before: less than one Home preload.
    static let homeLimit = 2 << 30
    static let restLimit = 1 << 30
    static let diskLimit: Int = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let free = (try? caches.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity ?? 0
        return min(homeLimit + restLimit, max(768 << 20, free / 10))
    }()
    private let diskBudget = ImageCache.diskLimit
    /// Its folder on disk (Settings → Storage measures it).
    static var diskFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cue-images", isDirectory: true)
    }

    private init() {
        // Sized to the hardware: the Apple TV HD has 2 GB total — a 256 MB
        // decoded-pixel cache there gets the app jetsammed.
        memory.countLimit = PerformanceProfile.imageCacheCount
        memory.totalCostLimit = PerformanceProfile.imageCacheBytes
        memory.delegate = costs
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskURL = caches.appendingPathComponent("cue-images", isDirectory: true)
        try? fm.createDirectory(at: diskURL, withIntermediateDirectories: true)
        // The LRU trim walks every cached file's attributes under a BARRIER —
        // thousands of files on a full 512 MB cache — and it used to run at
        // launch, exactly when the first screenful of posters is trying to
        // read from this same queue. Deferred past first paint; a trim is
        // housekeeping, and a cache a little over budget for ten seconds
        // costs nothing.
        ioQueue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.trimDisk() }
        // Under real memory pressure, decoded pixels are the cheapest thing to
        // give back (they re-decode from disk on demand) — dropping them here
        // is what keeps tvOS from jetsamming the whole app instead.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.memory.removeAllObjects() }
    }

    /// Decode `data` off the render path, downsampled (via ImageIO) to
    /// `budget` pixels on the longest side when the source is larger.
    ///
    /// Callers that know their rendered size pass a tight budget (a poster
    /// card never needs a 2000×3000 "original" — decoding it full-size costs
    /// ~24 MB where ~3 MB carries the identical rendered pixels). With no
    /// budget the device framebuffer cap applies (1920 on the 1080p HD, 3840
    /// on 4K devices) — beyond the framebuffer there is nothing more to show,
    /// so every path stays pixel-identical.
    /// `fill` (pixels): decoded just large enough to cover a card of that
    /// size, whatever the picture's shape — a 2:3 poster in a 4:5 card by
    /// its width, a backdrop by its height (a longest side can't say which).
    static func decodeDownsampled(_ data: Data, budget: CGFloat? = nil, fill: CGSize? = nil) -> UIImage? {
        var maxDim = min(budget ?? .greatestFiniteMagnitude,
                         PerformanceProfile.maxImagePixelSize)
        guard let src = CGImageSourceCreateWithData(data as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary) else {
            // Fallback: force the decode now so it doesn't happen lazily on
            // the render path while a row scrolls.
            let decoded = UIImage(data: data)
            return decoded?.preparingForDisplay() ?? decoded
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
            if let fill {
                let scale = max(fill.width / w, fill.height / h)
                maxDim = min(maxDim, (max(w, h) * scale).rounded(.up))
            }
            // Source already within the budget — plain decode.
            if max(w, h) <= maxDim {
                let decoded = UIImage(data: data)
                return decoded?.preparingForDisplay() ?? decoded
            }
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,   // decode now, off-main
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            let decoded = UIImage(data: data)
            return decoded?.preparingForDisplay() ?? decoded
        }
        return UIImage(cgImage: cg)
    }

    /// Every decoded picture out of memory (the player coming up): what's
    /// on screen stays, held by its views.
    func emptyMemory() { memory.removeAllObjects() }

    /// Synchronous memory-only lookup.
    func image(for key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    /// Off-main disk lookup. On a hit the image is promoted back into memory
    /// (under `memoryKey`, which carries the decode-budget bucket) and its
    /// file's mtime is touched so it survives LRU trimming. Disk stores the
    /// original encoded bytes keyed by URL, and beside it a smaller copy per
    /// size decoded (`keepResized`), keyed by `memoryKey` — read first.
    func diskImage(for key: String, budget: CGFloat? = nil, fill: CGSize? = nil, memoryKey: String? = nil,
                   turn: DecodeGate.Turn = .now, still: (@MainActor () -> Bool)? = nil) async -> UIImage? {
        await DecodeGate.shared.enter(turn)
        if let still, !(await still()) { await DecodeGate.shared.leave(turn); return nil }
        let image = await readDisk(for: key, budget: budget, fill: fill, memoryKey: memoryKey)
        await DecodeGate.shared.leave(turn)
        return image
    }

    private func readDisk(for key: String, budget: CGFloat?, fill: CGSize?, memoryKey: String?) async -> UIImage? {
        let fileURL = fileURL(for: key)
        // Its copy at this size, if one was kept (`keepResized`): a small
        // file, decoded as it is.
        let resizedURL = memoryKey.flatMap { $0 == key ? nil : self.copyURL(of: key, size: $0) }
        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                if let resizedURL, let small = try? Data(contentsOf: resizedURL),
                   let prepared = Self.decodeDownsampled(small, budget: budget, fill: fill) {
                    self.insertMemory(prepared, for: memoryKey ?? key)
                    continuation.resume(returning: prepared)
                    self.ioQueue.async { [weak self] in
                        self?.markUsed(resizedURL)
                    }
                    return
                }
                guard let data = try? Data(contentsOf: fileURL),
                      // Decode HERE (background, downsampled) — otherwise UIKit
                      // decodes lazily on first draw, i.e. on the render path
                      // while a row is scrolling.
                      let prepared = Self.decodeDownsampled(data, budget: budget, fill: fill) else {
                    continuation.resume(returning: nil)
                    // A file that isn't a picture (an error page stored
                    // before downloads were checked): gone, so the warm-ups,
                    // which skip what's on disk, fetch it again.
                    if self.fm.fileExists(atPath: fileURL.path) { try? self.fm.removeItem(at: fileURL) }
                    return
                }
                self.insertMemory(prepared, for: memoryKey ?? key)
                continuation.resume(returning: prepared)
                if let resizedURL { self.keepResized(prepared, of: data, at: resizedURL) }
                // Saved before originals were capped: capped now.
                let kept = Self.keptBytes(data)
                if kept.count < data.count { self.writeCacheFile(kept, to: fileURL) }
                // LRU bookkeeping only — never make the caller wait on a
                // filesystem attribute write.
                self.ioQueue.async { [weak self] in
                    self?.markUsed(fileURL)
                }
            }
        }
    }

    /// Store in memory now and persist the encoded bytes to disk in the
    /// background. Pass the original downloaded `data` to avoid re-encoding.
    /// `memoryKey` (when given) carries the decode-budget bucket; disk is
    /// always keyed by the plain URL.
    func insert(_ image: UIImage, for key: String, data: Data? = nil, memoryKey: String? = nil) {
        insertMemory(image, for: memoryKey ?? key)
        let payload = data ?? image.jpegData(compressionQuality: 0.9)
        guard let payload else { return }
        let fileURL = fileURL(for: key)
        let resizedURL = memoryKey.flatMap { $0 == key ? nil : self.copyURL(of: key, size: $0) }
        ioQueue.async { [self] in
            writeOriginal(payload, to: fileURL)
            if let resizedURL { keepResized(image, of: payload, at: resizedURL) }
        }
    }

    /// A picture decoded smaller than its file (`PictureSize`): that size
    /// kept on disk too, beside the original, so the next read from disk
    /// decodes a small file, not the original again (TMDB's are multi-MB
    /// 4K JPEGs). Only when it's really smaller — fewer pixels, under 70 %
    /// of the bytes; JPEG, or PNG for pictures with transparency (logos).
    /// On `ioQueue`.
    private func keepResized(_ image: UIImage, of original: Data, at fileURL: URL) {
        guard let cg = image.cgImage,
              let source = CGImageSourceCreateWithData(original as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              max(cg.width, cg.height) < max(w, h) * 9 / 10 else { return }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        guard let small = opaque ? image.jpegData(compressionQuality: 0.85) : image.pngData(),
              small.count < original.count * 7 / 10 else { return }
        writeCacheFile(small, to: fileURL)
    }

    /// The longest side kept on disk of a poster (any portrait) and of a
    /// logo (any picture with transparency): the largest either is ever
    /// drawn — a text-free poster filling a tall card by its width
    /// (~1750 px tall), the billboard's and Details' logo (560 pt, 1120 px).
    /// TMDB's originals are 3000 px posters and logos up to 12 MB; at
    /// full size they were most of the disk cache (Home's worst case
    /// ~1.7 GB, 80 % of it originals never drawn). Backdrops and stills
    /// stay whole: full screen draws them at the panel's 3840.
    private static let portraitKept = (1800 * PerformanceProfile.maxImagePixelSize / 3840).rounded()
    private static let logoKept = (1120 * PerformanceProfile.maxImagePixelSize / 3840).rounded()

    /// A downloaded picture as it's kept on disk (`keptBytes`). On `ioQueue`.
    private func writeOriginal(_ data: Data, to fileURL: URL) {
        writeCacheFile(Self.keptBytes(data), to: fileURL)
    }

    /// `data`, or — a poster or logo larger than it's ever drawn — a copy
    /// at that size (JPEG, PNG for transparency). One frame only: an
    /// animation is left as it is.
    static func keptBytes(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return data }
        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let cap: CGFloat
        if alpha { cap = logoKept } else if h > w * 1.1 { cap = portraitKept } else { return data }
        guard max(w, h) > cap * 1.1 else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: cap
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return data }
        let out = NSMutableData()
        let type = (alpha ? "public.png" : "public.jpeg") as CFString
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return data }
        CGImageDestinationAddImage(destination, small,
                                   alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length < data.count else { return data }
        return out as Data
    }

    /// A file read: its date moved to now for the trim (oldest go first),
    /// only once a day — the trim needs no finer, and every read was a
    /// write (~500 a session). On `ioQueue`.
    private func markUsed(_ file: URL) {
        let date = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard date.map({ Date().timeIntervalSince($0) > 24 * 60 * 60 }) ?? false else { return }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Raw encoded bytes from the disk layer, no decode — for consumers that
    /// decode themselves (the animated collection GIFs). Touches the file's
    /// mtime so a GIF in active rotation survives LRU trimming.
    func diskData(for key: String) async -> Data? {
        let fileURL = fileURL(for: key)
        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let data = try? Data(contentsOf: fileURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
                self?.ioQueue.async { [weak self] in
                    self?.markUsed(fileURL)
                }
            }
        }
    }

    /// Persist encoded bytes with no decoded image attached (same disk layer
    /// and LRU budget as artwork).
    func insertData(_ data: Data, for key: String) {
        let fileURL = fileURL(for: key)
        ioQueue.async { [self] in writeCacheFile(data, to: fileURL) }
    }

    /// One download per URL, however many callers want it.
    ///
    /// The same poster routinely appears in two rows, and the prefetch may
    /// already be fetching it — each of those was a separate round trip. Uses an
    /// unstructured task deliberately, so one caller cancelling (a cell
    /// scrolling away) does not cancel the fetch the others are waiting on.
    private actor DownloadCoalescer {
        private var inFlight: [String: Task<Data, Error>] = [:]

        func data(for url: URL) async throws -> Data {
            let key = url.absoluteString
            if let existing = inFlight[key] { return try await existing.value }
            let task = Task {
                let (data, response) = try await ImageCache.downloadSession.data(from: url)
                // An error page (404, 429, a CDN's 5xx) is no picture: it
                // was stored on disk as one, never decoded, and the disk
                // copy kept the warm-ups from fetching it again.
                if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                    throw DownloadError.status(http.statusCode)
                }
                guard !data.isEmpty else { throw DownloadError.empty }
                return data
            }
            inFlight[key] = task
            let result = await task.result
            inFlight[key] = nil
            return try result.get()
        }
    }

    private let downloads = DownloadCoalescer()

    enum DownloadError: Error {
        case status(Int), empty
        /// Worth asking again: anything but the server saying it has none.
        var transient: Bool {
            guard case .status(let code) = self else { return true }
            return code == 408 || code == 429 || code >= 500
        }
    }

    func download(_ url: URL) async throws -> Data {
        try await downloads.data(for: url)
    }

    /// `download`, asked again after a failure that may pass (the network,
    /// a timeout, a busy server) while `still` holds: 1, 3, 8, then 20 s
    /// apart, six tries in all. A card whose one try failed stayed empty —
    /// its edge and nothing else — until it was made again.
    func downloadRetrying(_ url: URL, still: (@MainActor () -> Bool)? = nil) async -> Data? {
        let waits: [Double] = [1, 3, 8, 20, 20]
        for attempt in 0 ... waits.count {
            do {
                return try await download(url)
            } catch {
                if let error = error as? DownloadError, !error.transient { return nil }
                guard attempt < waits.count else { return nil }
                try? await Task.sleep(for: .seconds(waits[attempt]))
                if Task.isCancelled { return nil }
                if let still, !(await still()) { return nil }
            }
        }
        return nil
    }

    /// Write one cached image body, recreating the cache directory if it has
    /// gone missing. Without the retry, anything that deletes the directory
    /// (Settings → "Clear cache", or tvOS reclaiming Caches/ under pressure)
    /// left every subsequent write failing silently — the disk layer was dead
    /// until the next launch and every poster came off the network again.
    private func writeCacheFile(_ data: Data, to fileURL: URL) {
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            try? fm.createDirectory(at: diskURL, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        // Re-arm the LRU trim after enough new bytes. It used to run exactly
        // once per launch (10s in), so a long browsing session could push the
        // store well past its 512 MB budget with no trim until next launch —
        // and an oversized Caches directory is what invites tvOS to purge the
        // WHOLE directory under pressure. Atomic: writes run on the
        // CONCURRENT ioQueue, so a plain counter would race.
        var shouldTrim = false
        bytesWrittenSinceTrim.mutate { count in
            count += data.count
            if count >= Self.trimRearmBytes { count = 0; shouldTrim = true }
        }
        if shouldTrim {
            trimDisk()
        }
    }

    /// Bytes written between trims (~one trim per 64 MB of fresh artwork —
    /// rare enough that the barrier walk stays negligible).
    private let bytesWrittenSinceTrim = Atomic<Int>(wrappedValue: 0)
    private static let trimRearmBytes = 64 << 20

    /// Off while the player is up (`PictureRelease`): pictures still
    /// decode for whoever asked, the cache keeps none (the launch's preload
    /// filled it back to 255 MB under a playing film).
    let keepsInMemory = Atomic<Bool>(wrappedValue: true)

    private func insertMemory(_ image: UIImage, for key: String) {
        guard keepsInMemory.wrappedValue else { return }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale) * 4
        if let old = memory.object(forKey: key as NSString) { costs.remove(old) }
        costs.add(image, cost, key: key)
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func fileURL(for key: String) -> URL {
        diskURL.appendingPathComponent(Self.fileName(key))
    }

    private static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A picture's copy at a size (`keepResized`): named after the picture
    /// first, so the trim knows whose it is (`protectHome`).
    private func copyURL(of url: String, size key: String) -> URL {
        diskURL.appendingPathComponent(Self.fileName(url) + "-" + Self.fileName(key).prefix(32))
    }

    /// Home's pictures, by file name (the picture's; its copies start with
    /// it): kept by the trim over everything else. Nil until Home has
    /// said, and the trim waits until then.
    private let homeFiles = Atomic<Set<String>?>(wrappedValue: nil)
    private var homeURLs = Set<String>()

    /// The pictures today's Home shows (every row's and the billboard's):
    /// protected from the trim. Called as Home's rows are drawn; only a
    /// change does anything.
    @MainActor func protectHome(_ urls: Set<String>) {
        guard urls != homeURLs else { return }
        homeURLs = urls
        trimQueue.async { [weak self] in
            self?.homeFiles.wrappedValue = Set(urls.map(Self.fileName))
        }
    }

    /// Warm the cache for images that will be needed soon (posters in rows
    /// below the fold). DISK-ONLY: persists the encoded bytes so the first real
    /// display is a disk hit (no network round-trip), and stops there.
    ///
    /// It deliberately does NOT decode or populate memory. The old version
    /// decoded each prefetched image at the full device cap (1920px on the HD —
    /// ~9 MB decoded for a poster drawn at ~330px) and inserted it under the
    /// PLAIN url key, but the display path (`RemoteImage`) only ever reads under
    /// a budget-bucketed key (`url#<budget>`). So every prefetch decode was both
    /// far too large AND stored under a key nothing reads — it just churned CPU
    /// and RAM (a real jetsam risk on the 2 GB box when a Home load prefetched
    /// 100+ posters) before being evicted, for zero display benefit. The display
    /// path decodes from this disk cache at its own tight per-card budget.
    /// The one live prefetch pass. Each Home reload used to spawn ANOTHER
    /// uncancellable detached task — N reloads stacked N endless download
    /// loops that kept running during playback.
    private var prefetchTask: Task<Void, Never>?

    func prefetch(urls: [String]) {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0).inserted }
        // Capped on EVERY tier — "all of them" was unbounded on 4K boxes.
        let limit = PerformanceProfile.isLowPower ? 36 : (PerformanceProfile.isMidPower ? 60 : 96)
        let candidates = Array(unique.prefix(limit))
        prefetchTask?.cancel()
        // Bounded, not one at a time. Serially this warmed up to 96 posters at
        // roughly 60ms each — about six seconds on a session configured for
        // twelve connections per host — so the prefetch usually lost its race
        // against the user and the scroll hit the network anyway. Kept modest so
        // it cannot starve the posters currently on screen.
        let window = PerformanceProfile.isLowPower ? 4 : (PerformanceProfile.isMidPower ? 6 : 8)
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func startNext() {
                    guard next < candidates.count, !Task.isCancelled else { return }
                    let urlString = candidates[next]
                    next += 1
                    group.addTask { [weak self] in
                        guard !Task.isCancelled, let self,
                              let url = URL(string: urlString) else { return }
                        let fileURL = self.fileURL(for: urlString)
                        if self.fm.fileExists(atPath: fileURL.path) { return }
                        // Same coalescer as the on-screen path, so a prefetch
                        // and a visible cell never download the same poster
                        // twice.
                        guard let data = try? await self.download(url) else { return }
                        self.ioQueue.async { self.writeOriginal(data, to: fileURL) }
                    }
                }
                for _ in 0 ..< min(window, candidates.count) { startNext() }
                while await group.next() != nil { startNext() }
            }
        }
    }

    /// Warm a SHORT list of high-priority URLs — the hero backdrops — outside
    /// the row prefetch above.
    ///
    /// Deliberately not routed through `prefetch(urls:)`: that keeps a single
    /// cancellable task handle, so the hero and the poster warm-up would cancel
    /// each other depending on which ran last, and the loser would silently do
    /// nothing. These also run at `.userInitiated` rather than `.utility`,
    /// because a hero backdrop is the largest image on the screen and the one
    /// the viewer is looking at, not something below the fold.
    func warm(urls: [String]) {
        var seen = Set<String>()
        // Eight parallel full-size backdrop downloads at user-initiated
        // priority land at the same instant as the first poster grid; on the
        // HD's older Wi-Fi (and the 3 GB box's decode budget) that contention
        // is visible, so the older tiers warm fewer.
        let limit = PerformanceProfile.isLowPower ? 3 : (PerformanceProfile.isMidPower ? 5 : 8)
        let unique = urls.filter { seen.insert($0).inserted }.prefix(limit)
        for urlString in unique {
            guard let url = URL(string: urlString) else { continue }
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let fileURL = self.fileURL(for: urlString)
                if self.fm.fileExists(atPath: fileURL.path) { return }
                // `download` coalesces, so warming a URL a visible view is
                // already fetching costs one request, not two.
                guard let data = try? await self.download(url) else { return }
                self.ioQueue.async { self.writeOriginal(data, to: fileURL) }
            }
        }
    }

    /// Get an image decoded into MEMORY under the key a `RemoteImage` with
    /// the same `maxDimension` / `maxPixels` looks up, so it is on screen from
    /// its first frame (no late fade-in). Returns once it is there, or at
    /// once if it already was; false when it could not be loaded.
    @discardableResult
    func preload(_ value: String, maxDimension: CGFloat? = nil, maxPixels: CGFloat? = nil,
                 turn: DecodeGate.Turn = .now, still: (@MainActor () -> Bool)? = nil) async -> Bool {
        let key = RemoteImage.memoryKey(value, maxDimension: maxDimension, maxPixels: maxPixels)
        if let hit = image(for: key) { return await trimLogo(hit, value, maxDimension) }
        let budget = RemoteImage.pixelBudget(maxDimension: maxDimension, maxPixels: maxPixels)
        if let disk = await diskImage(for: value, budget: budget, memoryKey: key, turn: turn, still: still) {
            return await trimLogo(disk, value, maxDimension)
        }
        if let still, !(await still()) { return false }
        guard let url = URL(string: value), let data = try? await download(url),
              let prepared = await DecodeGate.shared.run(turn, still: still, {
                  ImageCache.decodeDownsampled(data, budget: budget)
              }) else { return false }
        insert(prepared, for: value, data: data, memoryKey: key)
        return await trimLogo(prepared, value, maxDimension)
    }

    /// The billboard's, Details' and the stage's logo (`PictureSize.logo`):
    /// trimmed ahead too, off the main thread, so `RemoteImage` shows it
    /// from its first frame.
    private func trimLogo(_ image: UIImage, _ value: String, _ size: CGFloat?) async -> Bool {
        // Details' picture: its colours worked out ahead too (`TitleBands`).
        if let size, await size == PictureSize.screen, let cg = image.cgImage {
            await TitleBands.shared.prepare(value, from: cg)
            return true
        }
        guard let size, await size == PictureSize.logo, LogoFit.cachedTrim(key: value) == nil else { return true }
        _ = await LogoFit.trimmedInBackground(image, key: value)
        return true
    }

    /// On disk as a picture, downloaded if it isn't: true when it is,
    /// false when the server has none (a 404, or not a picture), nil when
    /// the network failed (worth asking again later).
    func fetchPicture(_ value: String) async -> Bool? {
        if let data = await diskData(for: value), Self.isPicture(data) { return true }
        guard let url = URL(string: value) else { return false }
        do {
            let data = try await download(url)
            guard Self.isPicture(data) else { return false }
            let fileURL = fileURL(for: value)
            ioQueue.async { self.writeOriginal(data, to: fileURL) }
            return true
        } catch let error as DownloadError where !error.transient {
            return false
        } catch {
            return nil
        }
    }

    static func isPicture(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0
    }

    /// Downloaded into the DISK cache only, not decoded (the background
    /// queue further from focus). True when it's on disk.
    @discardableResult
    func fetchToDisk(_ value: String) async -> Bool {
        let fileURL = fileURL(for: value)
        if fm.fileExists(atPath: fileURL.path) { return true }
        guard let url = URL(string: value), let data = try? await download(url) else { return false }
        ioQueue.async { self.writeOriginal(data, to: fileURL) }
        return true
    }

    /// On DISK at `maxDimension`, not kept in memory: the original
    /// downloaded if it isn't there, and its copy at that size made
    /// (`keepResized`), so a later decode reads a small file (the queue's
    /// further titles — decoding all into memory would evict the first
    /// screen's). Once per launch per size.
    @discardableResult
    @MainActor func keepOnDisk(_ value: String, maxDimension: CGFloat) async -> Bool {
        let key = RemoteImage.memoryKey(value, maxDimension: maxDimension, maxPixels: nil)
        let budget = RemoteImage.pixelBudget(maxDimension: maxDimension, maxPixels: nil)
        return await keepOnDisk(value, key: key, budget: budget, fill: nil)
    }

    /// As above, for the size a card reads under `key` (`FixedFocusImages`'
    /// sizing: by its longest side, `budget`, or to cover it, `fill`).
    @discardableResult
    @MainActor func keepOnDisk(_ value: String, key: String, budget: CGFloat?, fill: CGSize?) async -> Bool {
        if image(for: key) != nil || keptOnDisk.contains(key) { return true }
        let resizedURL = copyURL(of: value, size: key)
        if fm.fileExists(atPath: resizedURL.path) { keptOnDisk.insert(key); return true }
        let data: Data
        if let saved = await diskData(for: value) {
            data = saved
        } else {
            guard let url = URL(string: value), let downloaded = try? await download(url) else { return false }
            data = downloaded
            let fileURL = fileURL(for: value)
            ioQueue.async { self.writeOriginal(downloaded, to: fileURL) }
        }
        if let image = await DecodeGate.shared.run(.ahead, { ImageCache.decodeDownsampled(data, budget: budget, fill: fill) }) {
            ioQueue.async { self.keepResized(image, of: data, at: resizedURL) }
        }
        keptOnDisk.insert(key)
        return true
    }
    @MainActor private var keptOnDisk = Set<String>()

    /// Every picture on disk removed (Settings → Storage); what's decoded
    /// in memory stays (cards on screen keep theirs) until it's evicted.
    @MainActor func clearDisk() async {
        keptOnDisk = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            ioQueue.async(flags: .barrier) { [self] in
                for file in (try? fm.contentsOfDirectory(at: diskURL, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: file)
                }
                done.resume()
            }
        }
    }

    /// As `preload`, from MEMORY or DISK only — never the network (the
    /// launch: nothing waits for it; what isn't on disk loads as usual).
    /// True when it's now decoded in memory.
    @discardableResult
    func preloadFromDisk(_ value: String, maxDimension: CGFloat? = nil) async -> Bool {
        let key = RemoteImage.memoryKey(value, maxDimension: maxDimension, maxPixels: nil)
        if image(for: key) != nil { return true }
        let budget = RemoteImage.pixelBudget(maxDimension: maxDimension, maxPixels: nil)
        return await diskImage(for: value, budget: budget, memoryKey: key) != nil
    }

    /// Evict oldest files (by mtime) until the directory is under budget.
    ///
    /// The SCAN runs on its own queue, not on `ioQueue`: `contentsOfDirectory`
    /// plus a `resourceValues` call per file is thousands of stats on a full
    /// 512 MB cache, and running that under a `.barrier` on the concurrent read
    /// queue drained and then blocked every already-cached poster's read for the
    /// whole walk — placeholders persisted on a warm cache. Only the removals
    /// take the barrier, and those are fast.
    private let trimQueue = DispatchQueue(label: "cue.imagecache.trim", qos: .utility)

    /// Home's pictures kept, the rest within `restLimit`, oldest out first;
    /// then, past the whole budget or Home's own, Home's oldest too.
    private var trimWaiting = false   // on trimQueue
    private func trimDisk() {
        trimQueue.async { [weak self] in
            guard let self else { return }
            // Before Home has said what it shows, everything looks
            // unprotected: later.
            guard let home = self.homeFiles.wrappedValue else {
                guard !self.trimWaiting else { return }
                self.trimWaiting = true
                self.trimQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.trimWaiting = false
                    self?.trimDisk()
                }
                return
            }
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let contents = try? self.fm.contentsOfDirectory(
                at: self.diskURL, includingPropertiesForKeys: keys
            ) else { return }
            var homeSide: [(url: URL, size: Int, date: Date)] = []
            var rest: [(url: URL, size: Int, date: Date)] = []
            for url in contents {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let size = values.fileSize,
                      let date = values.contentModificationDate else { continue }
                let name = url.lastPathComponent
                let picture = name.firstIndex(of: "-").map { String(name[..<$0]) } ?? name
                if home.contains(picture) { homeSide.append((url, size, date)) } else { rest.append((url, size, date)) }
            }
            var homeTotal = homeSide.reduce(0) { $0 + $1.size }
            var restTotal = rest.reduce(0) { $0 + $1.size }
            var doomed: [URL] = []
            rest.sort { $0.date < $1.date }   // oldest first
            for file in rest {
                if restTotal <= Self.restLimit, homeTotal + restTotal <= self.diskBudget { break }
                doomed.append(file.url)
                restTotal -= file.size
            }
            homeSide.sort { $0.date < $1.date }
            for file in homeSide {
                if homeTotal <= Self.homeLimit, homeTotal + restTotal <= self.diskBudget { break }
                doomed.append(file.url)
                homeTotal -= file.size
            }
            guard !doomed.isEmpty else { return }
            self.ioQueue.sync(flags: .barrier) { [weak self] in
                guard let self else { return }
                for url in doomed { try? self.fm.removeItem(at: url) }
            }
        }
    }
}

// MARK: - Pictures while the player is up

/// While the player is up the pages out of sight (the other tabs, the
/// pages on them) let their pictures go and the memory cache is emptied:
/// ~350–450 MB back for the film (tvOS can end an app over memory with no
/// warning; two deaths in ten episodes on the TV). The page under the
/// player — Details, the stage, Home under Continue Watching — keeps what
/// it shows, so the way back is as before. A second after the player
/// closes, the rest takes its pictures back from disk, before a switch.
@MainActor
enum PictureRelease {
    static let release = Notification.Name("cue.picturesRelease")
    static let restore = Notification.Name("cue.picturesRestore")
    private static var playerUp = false

    static func player(up: Bool) {
        guard up != playerUp else { return }
        playerUp = up
        DiskWrites.player(up: up)
        if up {
            NotificationCenter.default.post(name: release, object: nil)
            let before = ImageCache.shared.memoryCost
            ImageCache.shared.keepsInMemory.wrappedValue = false
            ImageCache.shared.emptyMemory()
            AppProbe.nav("pictures let go for the player (cache \(before >> 20) MB)")
        } else {
            ImageCache.shared.keepsInMemory.wrappedValue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard !playerUp else { return }
                NotificationCenter.default.post(name: restore, object: nil)
                AppProbe.nav("pictures back after the player")
            }
        }
    }

    /// Out of sight: in no window, or under a hidden or transparent layer
    /// (a hidden tab is only transparent; SwiftUI's opacity may sit on a
    /// layer of its own, so layers, not views).
    static func outOfSight(_ view: UIView) -> Bool {
        guard view.window != nil else { return true }
        var layer: CALayer? = view.layer
        while let current = layer {
            if current.isHidden || current.opacity < 0.01 { return true }
            layer = current.superlayer
        }
        return false
    }
}

// MARK: - Remote image

/// Cached async image with a shimmer placeholder and a crossfade-in. Keeps the
/// previously shown image on screen while a new URL loads, so changing the hero
/// backdrop is a smooth crossfade rather than a flash.
/// A LOGO'S SIZE BY AREA: every logo covers about the same area, so a
/// wide one isn't huge and a square one tiny (fitting a box gave each the
/// box's width or height, whatever its shape) — within `maxSize`.
struct LogoFit {
    let area: CGFloat
    let maxSize: CGSize

    func size(for image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let ratio = image.width / image.height
        let height = (area / ratio).squareRoot(), width = height * ratio
        let scale = min(1, maxSize.width / width, maxSize.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }

    /// The trimmed logos shown, by their own bytes: room for every logo
    /// Home and Details show at once and then some (evicted, a card's logo
    /// would come in after its picture). Unlimited, and each a crop that
    /// kept its whole original alive, it held every logo ever seen.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 << 20
        cache.countLimit = 400
        return cache
    }()

    private static func keep(_ image: UIImage, _ key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// The logo without its empty (transparent) edges, so its shape is the
    /// drawing's and it starts where the text does. Made once per logo.
    @MainActor
    static func trimmed(_ image: UIImage, key: String) -> UIImage {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let result = trim(image) ?? image
        keep(result, key)
        return result
    }

    /// Made already (nil: not yet).
    static func cachedTrim(key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    /// `trimmed`, off the main thread: it reads every pixel, and on the
    /// main thread a row's new logos stalled its move (100–200 ms, the
    /// page jumping at the first visit).
    static func trimmedInBackground(_ image: UIImage, key: String) async -> UIImage {
        if let hit = cachedTrim(key: key) { return hit }
        let result = await Task.detached(priority: .userInitiated) { trim(image) ?? image }.value
        keep(result, key)
        return result
    }

    private static func trim(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        switch cg.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst: return nil
        default: break
        }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Anything fainter than this is empty (soft glows, stray pixels).
        let threshold: UInt8 = 12
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where pixels[row + x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        if minX == 0, minY == 0, maxX == w - 1, maxY == h - 1 { return nil }
        // (The buffer's rows run top to bottom, as the image's.) Drawn into
        // a buffer of its own size: a crop keeps the whole original alive.
        let width = maxX - minX + 1, height = maxY - minY + 1
        guard let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: width, height: height)),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                                          ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let copy = context.makeImage() else { return nil }
        return UIImage(cgImage: copy, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// The sizes pictures are decoded at, in points: each its largest on
/// screen (focused, zoomed). One picture, one size, one decode — what is
/// preloaded is what is shown.
@MainActor
enum PictureSize {
    /// Portrait posters (one size everywhere), focused.
    static var poster: CGFloat {
        FixedFocusMetrics.posterCard.height * (1 + FixedFocusMetrics.focusLift(FixedFocusMetrics.posterCard))
    }
    /// Landscape cards (Continue Watching, episode stills, collection
    /// tiles, wide cards): the box-wide card with a little room, as the
    /// pictures already on disk were cut.
    static var landscape: CGFloat { FixedFocusMetrics.boxWidth * 1.04 }
    /// A large row's open card, focused (16:9, as its backdrops).
    static var openCard: CGFloat { card(FixedFocusMetrics.featureCard) }
    /// A large row's poster (never grown).
    static var featurePoster: CGFloat { FixedFocusMetrics.featurePoster.height }
    /// A card showing a picture of its own shape (a portrait, a studio's
    /// logo on its square), focused: its longer side. The poster's too.
    static func card(_ size: CGSize) -> CGFloat {
        max(size.width, size.height) * (1 + FixedFocusMetrics.focusLift(size))
    }
    /// A card cut from a picture of another shape (the tall cards, Top 10's
    /// squares, Today's Pick: posters or backdrops), focused: decoded to
    /// cover it (`ImageCache.decodeDownsampled(fill:)`).
    static func fill(_ size: CGSize) -> CGSize {
        let grown = 1 + FixedFocusMetrics.focusLift(size)
        return CGSize(width: size.width * grown, height: size.height * grown)
    }
    /// A landscape card's logo.
    static var cardLogo: CGFloat { landscape * 0.55 }
    /// Full screen: the billboard, Details, the stage, at the panel's own
    /// pixels (2560 px on the 4K boxes was tried: the softening showed).
    static var screen: CGFloat { StagePictureView.pictureSize.width }
    /// The billboard's and Details' logo.
    static var logo: CGFloat { TitleBlock.logoWidth }
}

struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    var alignment: Alignment = .center
    /// Longest rendered side in POINTS, when the caller knows it (poster and
    /// episode cards do). Decoding is capped at 1.5× this size in pixels —
    /// still supersampled relative to what's drawn, so the rendered output is
    /// identical, but a grid of cards stops decoding full "original" TMDB art
    /// it can never show. `nil` (heroes/backdrops) = device framebuffer cap.
    var maxDimension: CGFloat? = nil
    /// Hard decode cap in PIXELS on the longest side, for full-bleed art that
    /// has no point size to derive from (see `PerformanceProfile.backdropPixelCap`).
    var maxPixels: CGFloat? = nil
    /// Show the placeholder while loading (and when it fails). Off for LOGOS:
    /// transparent art over a picture — a dark box behind it looked broken;
    /// nothing at all until the logo is there reads better.
    var showsPlaceholder = true
    /// Shown instead when the image can't be loaded (e.g. a logo → the
    /// title as text).
    var fallback: AnyView? = nil
    /// A LOGO: trimmed of its empty edges and sized by area (`LogoFit`),
    /// the view hugging it (something sits on it) — instead of filling the
    /// room it's given. Nothing while it loads.
    var logoFit: LogoFit? = nil

    @State private var image: UIImage?
    @State private var shownKey: String?
    @State private var failed = false

    init(url: String?, contentMode: ContentMode = .fill, alignment: Alignment = .center,
         maxDimension: CGFloat? = nil, maxPixels: CGFloat? = nil, showsPlaceholder: Bool = true,
         fallback: AnyView? = nil, logoFit: LogoFit? = nil) {
        self.url = url
        self.logoFit = logoFit
        self.showsPlaceholder = showsPlaceholder
        self.fallback = fallback
        self.contentMode = contentMode
        self.alignment = alignment
        self.maxDimension = maxDimension
        self.maxPixels = maxPixels
        // A memory-cache hit is on screen from the FIRST frame, with no
        // placeholder and no fade. Without this a poster inside a view that
        // slides in (the player's info sheet) appeared a beat after its card,
        // fading in over a black box while the card was still moving.
        // A logo only once trimmed (`load` trims it off the main thread:
        // trimmed in `body`, a new logo stalled a move, the stage's grow).
        if let url, logoFit == nil || LogoFit.cachedTrim(key: url) != nil,
           let cached = ImageCache.shared.image(for: Self.memoryKey(url, maxDimension: maxDimension, maxPixels: maxPixels)) {
            _image = State(initialValue: cached)
            _shownKey = State(initialValue: url)
        }
    }

    var body: some View {
        if let logoFit {
            fitted(logoFit)
        } else {
            filling
        }
    }

    private func fitted(_ fit: LogoFit) -> some View {
        // (An empty Group never starts its task: a zero-size anchor.)
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(width: 0, height: 0)
            if let image, let key = shownKey {
                let logo = LogoFit.trimmed(image, key: key)
                let size = fit.size(for: logo.size)
                // A dark logo (made for a bright poster: The Ancient Magus'
                // Bride's black lettering) drawn white at primary, as the
                // cards' (`FixedFocusLogo.isDark`): on the picture it
                // didn't read.
                Image(uiImage: logo)
                    .renderingMode(FixedFocusLogo.isDark(logo) ? .template : .original)
                    .resizable()
                    .foregroundStyle(CueInk.primary)
                    .frame(width: size.width, height: size.height)
                    .id(shownKey)
                    .transition(.opacity)
            } else if failed, let fallback {
                fallback.transition(.opacity)
            }
        }
        .task(id: url) { await load(url) }
    }

    private var filling: some View {
        Color.clear.overlay(alignment: alignment) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .id(shownKey)
                    .transition(.opacity)
            } else if failed, let fallback {
                fallback.transition(.opacity)
            } else if showsPlaceholder {
                placeholder
            }
        }
        .clipped()
        .task(id: url) { await load(url) }
    }

    /// Pixel budget for the decode (longest side), from the rendered size
    /// and/or an explicit pixel cap.
    private var pixelBudget: CGFloat? {
        Self.pixelBudget(maxDimension: maxDimension, maxPixels: maxPixels)
    }

    /// The picture's longest side in pixels: its largest size on screen in
    /// points, at the screen's scale — nothing more (decoding 1.5× larger and
    /// rounding up to a ladder of sizes cost up to 3× the memory). Callers
    /// use the few `PictureSize`s, so one picture has one decode.
    static func pixelBudget(maxDimension: CGFloat?, maxPixels: CGFloat?) -> CGFloat? {
        let fromPoints = maxDimension.map { ($0 * UIScreen.main.scale).rounded(.up) }
        switch (fromPoints, maxPixels) {
        case (let a?, let b?): return min(a, b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }

    static func memoryKey(_ value: String, maxDimension: CGFloat?, maxPixels: CGFloat?) -> String {
        pixelBudget(maxDimension: maxDimension, maxPixels: maxPixels).map { "\(value)#\(Int($0))" } ?? value
    }

    /// Memory-cache key: the URL plus the budget bucket, so a small card decode
    /// is never handed to a full-screen consumer of the same URL (and vice
    /// versa). Disk stays keyed by plain URL — encoded bytes fit every size.
    private func memoryKey(_ value: String) -> String {
        pixelBudget.map { "\(value)#\(Int($0))" } ?? value
    }

    /// Commit a loaded image, fading only when "Artwork fade-in" is on
    /// (Settings → Performance) — each fade re-renders the cell for its
    /// duration, which adds up during a fast row scroll on older boxes.
    private func show(_ newImage: UIImage?, key: String?, duration: Double) {
        if PerformanceSettingsStore.shared.motionOn {
            withAnimation(.easeOut(duration: duration)) { image = newImage; shownKey = key }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { image = newImage; shownKey = key }
        }
    }

    private func load(_ value: String?) async {
        guard let value, let parsed = URL(string: value) else {
            show(nil, key: nil, duration: 0.2)
            failed = value != nil
            return
        }
        if value == shownKey { return }
        failed = false
        if let cached = ImageCache.shared.image(for: memoryKey(value)) {
            guard await trimmed(cached, key: value) else { return }
            show(cached, key: value, duration: 0.28)
            return
        }
        // Disk hit: survives relaunch, so a previously seen poster shows without
        // a network round-trip.
        if let disk = await ImageCache.shared.diskImage(
            for: value, budget: pixelBudget, memoryKey: memoryKey(value)
        ) {
            if Task.isCancelled { return }
            guard await trimmed(disk, key: value) else { return }
            show(disk, key: value, duration: 0.28)
            return
        }
        // Keep the current image visible while the replacement downloads.
        // Coalesced: the same poster can appear in two rows at once, or race the
        // prefetch already fetching it, and each of those used to be its own
        // download.
        guard let data = await ImageCache.shared.downloadRetrying(parsed) else {
            if !Task.isCancelled, image == nil { withAnimation(.easeOut(duration: 0.2)) { failed = true } }
            return
        }
        guard !Task.isCancelled else { return }
        // Decode off the render path (UIKit otherwise decodes lazily on first
        // draw — a scroll hitch per newly visible poster), downsampled to this
        // view's own pixel budget (a poster card must not decode a full-res
        // backdrop-sized original).
        let budget = pixelBudget
        guard let prepared = await DecodeGate.shared.run(.now, {
            ImageCache.decodeDownsampled(data, budget: budget)
        }) else {
            if !Task.isCancelled, image == nil { withAnimation(.easeOut(duration: 0.2)) { failed = true } }
            return
        }
        if Task.isCancelled { return }
        ImageCache.shared.insert(prepared, for: value, data: data, memoryKey: memoryKey(value))
        guard await trimmed(prepared, key: value) else { return }
        show(prepared, key: value, duration: 0.35)
    }

    /// A logo trimmed off the main thread before it's shown (`fitted` then
    /// finds it made). False: no longer wanted.
    private func trimmed(_ image: UIImage, key: String) async -> Bool {
        guard logoFit != nil, LogoFit.cachedTrim(key: key) == nil else { return true }
        _ = await LogoFit.trimmedInBackground(image, key: key)
        return !Task.isCancelled
    }

    private var placeholder: some View {
        PlaceholderShimmer()
    }
}

/// While an image downloads: the cards' placeholder (`FixedFocusPlaceholder`
/// — the soft fill, breathing on Core Animation, so many at once cost the
/// main thread nothing), square: the caller's shape clips it.
struct PlaceholderShimmer: UIViewRepresentable {
    func makeUIView(context: Context) -> FixedFocusPlaceholder {
        let view = FixedFocusPlaceholder()
        view.layer.cornerRadius = 0
        return view
    }

    func updateUIView(_ view: FixedFocusPlaceholder, context: Context) {}
}

// MARK: - Poster card

struct PosterCard: View {
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var layout: HomeCatalogSettingsStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused

    let item: MetaItem
    var progress: Double? = nil

    private var cardWidth: CGFloat { GridPoster.width }
    private var cardHeight: CGFloat { cardWidth * 3 / 2 }
    private var cornerRadius: CGFloat { GridPoster.cornerRadius }

    /// Explicit progress wins; otherwise an O(1) Continue Watching lookup so
    /// a started movie/show carries its progress bar EVERYWHERE it appears
    /// (home rows, search, discover, library…), not just the CW row.
    private var effectiveProgress: Double? {
        if let progress { return progress }
        return progressStore.continueFractions[item.id]
    }

    /// The native CardButtonStyle platter supplies focus (raise + trackpad
    /// wiggle), so the card's own ring / scale / shadow / caption are
    /// suppressed — posters read as clean "icons".
    // NOTE: a `private var atv: Bool { true }` used to sit here, left over from
    // the multi-theme era. Because it was a constant, `&& !atv` made two shipped
    // settings unreachable: the focused-poster drop shadow (Settings →
    // Performance → "Card shadows", whose copy promises shadows under posters)
    // and the poster caption (Settings → Layout → "Poster labels"). Both are
    // wired to their real settings below.

    /// Focus ring fallback: a single stroked outline is one vector stroke —
    /// no offscreen pass, nothing recomposited per frame.
    private var showsFocusRing: Bool {
        guard isFocused else { return false }
        // The glow this used to defer to no longer exists (it was always
        // `.clear` and has been removed), and the black drop shadow below is
        // disabled on this style too — so "shadows are on" can no longer stand
        // in for a focus cue. Ring unless something else actually moves the
        // card: the platter's raise/wiggle, or the zoom. With Reduce Motion on,
        // BOTH of those are suppressed while the shadow stays, which left
        // a focused poster with no indicator at all.
        return !perf.motionOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.sm) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: item.poster, maxDimension: cardHeight)
                    .aspectRatio(2 / 3, contentMode: .fill)
                if let progress = effectiveProgress, progress > 0 {
                    ProgressStrip(fraction: progress)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(CuePalette.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Fusion (§13.4): dim unfocused cards a touch so the focused one
            // pops. This USED to be .saturation(0.94) + .brightness(-0.05) — two
            // color-matrix filters, each an offscreen render pass, on EVERY
            // unfocused card, every scroll frame (the single biggest scroll cost
            // in this theme, and brutal in the simulator, which composites
            // offscreen passes far slower than the device). A flat dark overlay
            // is a plain alpha composite — no offscreen pass — for the same
            // "focused pops" read. Nothing is drawn when focused.
            .overlay {
                // Fusion: unfocused cards rest slightly darker so the focused
                // one pops (flat overlay — no live filters).
                if !isFocused {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.11))
                }
            }
            .overlay(alignment: .topTrailing) {
                if watched.isWatched(item) { WatchedBadge().padding(10) }
            }
            .overlay(
                // Stremio marks focus with a thicker purple border.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(showsFocusRing ? CuePalette.focusRing : .clear,
                                  lineWidth: 3)
            )
            // FOCUSED card only. A drop shadow is an offscreen render pass per
            // card; with the old always-on ambient shadow every visible poster
            // paid one, which is a large share of the scroll cost on the
            // A8/A10X boxes. One shadow (the focused pop) keeps the depth cue.
            .shadow(color: .black.opacity(isFocused ? 0.65 : 0),
                    radius: isFocused ? 22 : 0, y: 10)

            // No caption here. Every screen that wants one wraps this card in
            // `GridPosterCell`, which draws `ATVCardCaption` as a SIBLING below
            // the button — keeping the poster a clean tile instead of letting
            // the native platter bridge artwork and text together. That is where
            // Settings → Layout → "Poster labels" is honoured.
        }
        // 1.0, i.e. no scale of our own: the native tvOS card platter supplies
        // the lift and the trackpad tilt. (This used to branch on a theme flag
        // that has been a constant `true` since the other themes were retired.)
        .focusLift(1.0, isFocused)
    }
}

struct ProgressStrip: View {
    let fraction: Double

    var body: some View {
        // No GeometryReader: a full-width fill Capsule scaled horizontally to
        // the fraction. Every Continue Watching card carries one of these, and
        // GeometryReader forces each into its own layout pass — measurable
        // scroll cost across a row of them. scaleEffect is a cheap transform.
        Capsule().fill(Color.white.opacity(0.35))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(CuePalette.secondary)
                    .scaleEffect(x: CGFloat(min(max(fraction, 0.02), 1)), y: 1, anchor: .leading)
            }
            .frame(height: 6)
    }
}

/// The app's ONE glass language — every glass element (top bar, action
/// buttons, row end cards, …) uses these, so surface, highlight and text
/// never drift apart:
/// - `glassSurface`: the material (real Liquid Glass where available);
/// - `glassHighlight`: the selection / focus marker ON glass — itself glass,
///   tinted: bright when focused (tvOS focus look, like the system glass
///   buttons), faint when merely current;
/// - `AppGlass` text colours: `text` (white), `textMuted` (grey),
///   `textOnFocus` (dark, on the bright focus highlight).
enum AppGlass {
    static let focusTint = Color.white.opacity(0.92)
    static let currentTint = Color.white.opacity(0.18)
    /// (Nothing in the UI is pure white — `FixedFocusText.primary`.)
    static let text = CueInk.primary
    static let textMuted = CueInk.secondary
    static let textOnFocus = Color.black.opacity(0.85)
    /// THE glass: every Liquid Glass surface in the app is this one —
    /// `.regular`, darkened by this tint (text stays crisp over bright art;
    /// tried: untinted, Apple's as it is).
    /// Only floating things are glass (docs/UI-DESIGN.md §1).
    static let surfaceTint = Color.black.opacity(0.3)

    /// Real Liquid Glass is used (tvOS 26+, boxes that can afford it).
    static var isReal: Bool {
        if #available(tvOS 26.0, *) {
            return !(PerformanceProfile.isLowPower || PerformanceProfile.isMidPower)
        }
        return false
    }
}

/// THE FLAT CONTROL — everything in the page that you press (buttons,
/// pills, tabs, keys, rows, tiles): translucent white at rest, solid white
/// with dark content when focused. Each control keeps its own shape and
/// size; these are its colours (docs/UI-DESIGN.md §1).
enum FlatControl {
    /// (Light: white over the grey, as tvOS's light rows.)
    static let rest = CueInk.fill(dark: 0.13, light: 0.32)
    /// Lists of many (Settings rows): fainter, or the page turns grey.
    static let restSubtle = CueInk.fill(dark: 0.07, light: 0.24)
    /// The current one of a set (a selected pill or tab).
    static let selected = CueInk.fill(dark: 0.28, light: 0.55)
    static let focus = Color.white
    static let content = CueInk.color(1)
    static let contentMuted = AppGlass.textMuted
    static let contentOnFocus = Color.black
    static let focusChange: Animation = .easeOut(duration: 0.18)
}

/// A choice in the page as a pill (filters, tabs, shapes): the flat
/// control — the selected one on the brighter fill. Put it in a Button's
/// label; it reads the focus itself.
struct FlatChip: View {
    @Environment(\.isFocused) private var isFocused
    let label: String
    var selected = false

    var body: some View {
        Text(label)
            .font(.system(size: 24, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(height: 52)
            .foregroundStyle(isFocused ? FlatControl.contentOnFocus : FlatControl.content)
            .background(Capsule().fill(isFocused ? FlatControl.focus
                                       : selected ? FlatControl.selected : FlatControl.rest))
            .scaleEffect(isFocused ? 1.06 : 1)
            .animation(FlatControl.focusChange, value: isFocused)
    }
}

/// The selection / focus marker on glass (see `AppGlass`).
struct GlassHighlight<S: Shape>: View {
    let focused: Bool
    let shape: S
    /// Another tint than the focus / current ones (e.g. `AppGlass.idleTint`
    /// for glass that is an item itself, not a marker).
    var tint: Color? = nil
    /// Glass at all (false: a plain fill — for markers in the page, which
    /// are flat).
    var glass = true

    var body: some View {
        let tint = tint ?? (focused ? AppGlass.focusTint : AppGlass.currentTint)
        if #available(tvOS 26.0, *), glass, AppGlass.isReal {
            Color.clear.glassEffect(.regular.tint(tint), in: shape)
        } else {
            shape.fill(tint)
        }
    }
}

/// THE APP'S CONTROL STYLE — the top bar's: items in one floating glass
/// capsule, and ONE highlight that glides to the current item (bright white
/// while the control has focus — dark content on it — faint otherwise).
/// Everything button-like is built from this: the top navigation, the
/// billboard's position dots, …
///
/// Use: lay the items out in an `HStack(spacing: 0)`, mark each with
/// `.glassPillItem(id, in: namespace)`, and close the stack with
/// `.glassPill(highlight: currentID, in: namespace, focused: …)`.
enum GlassPill {
    /// Sizes of a standard control (the top bar). Text on a TV shouldn't go
    /// below ~23–25 pt (the system's caption sizes); 24 pt semibold in a
    /// 48 pt item gives a 60 pt pill.
    static let itemHeight: CGFloat = 48
    static let textSize: CGFloat = 24
    static let iconSize: CGFloat = 22
    static let textPadding: CGFloat = 22
    /// Between the pill's edge and its items (and their highlight).
    static let inset: CGFloat = 6
    /// The highlight gliding to another item, and changing with focus.
    static let glide: Animation = .smooth(duration: 0.3)
    static let focusChange: Animation = .easeOut(duration: 0.2)

    /// An item's content colour: dark on the bright focus highlight, white
    /// when current, muted otherwise.
    static func contentColor(current: Bool, onFocusHighlight: Bool) -> Color {
        onFocusHighlight ? AppGlass.textOnFocus : current ? AppGlass.text : AppGlass.textMuted
    }
}

extension View {
    /// One item of a glass pill: where the highlight goes when `id` is the
    /// current one.
    func glassPillItem<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        matchedGeometryEffect(id: id, in: namespace, isSource: true)
    }

    /// Closes a row of `glassPillItem`s into the app's glass pill, with the
    /// highlight on the item `id` (`inset`: `GlassPill.inset`, less for
    /// small pills).
    @MainActor
    func glassPill<ID: Hashable>(highlight id: ID, in namespace: Namespace.ID, focused: Bool,
                                 inset: CGFloat = GlassPill.inset) -> some View {
        glassHighlight(on: id, in: namespace, focused: focused)
            .padding(inset)
            // The app's glass surface (see `AppGlass`).
            .background { Color.clear.liquidGlass(in: Capsule()) }
    }

    /// Just the gliding highlight behind a row of `glassPillItem`s, without
    /// the pill around them (for items that are glass themselves, like the
    /// billboard's dots).
    @MainActor
    func glassHighlight<ID: Hashable>(on id: ID, in namespace: Namespace.ID, focused: Bool,
                                      glass: Bool = true) -> some View {
        background {
            GlassHighlight(focused: focused, shape: Capsule(), glass: glass)
                .matchedGeometryEffect(id: id, in: namespace, isSource: false)
                .animation(GlassPill.glide, value: id)
                .animation(GlassPill.focusChange, value: focused)
        }
    }
}

/// Liquid Glass on tvOS 26, translucent material earlier — the one frosted
/// treatment every glass surface in the app goes through (rail, filter pills,
/// search bar, detail icon circles, season chips).
extension View {
    @MainActor
    /// `untinted`: Apple's dark glass without our tint (the hold menus,
    /// Details' buttons: the tint made them a dark slab).
    func liquidGlass<S: Shape>(in shape: S, untinted: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, untinted: untinted))
    }
}

/// The one loading symbol: three dots rising and falling one after the other,
/// the light going with them, a brief rest between rounds. Hidden until it runs. Only layers move, so it costs playback nothing.
final class LoadingSymbol: UIView {
    private var dots: [CALayer] = []
    private(set) var isAnimating = false

    var color: UIColor = CueInk.ui(FixedFocusText.primary) {
        didSet { paint() }
    }

    init(size: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isHidden = true
        isUserInteractionEnabled = false
        let diameter = (size * 0.22).rounded()
        let gap = diameter * 0.7
        let row = 3 * diameter + 2 * gap
        dots = (0..<3).map { index in
            let dot = CALayer()
            dot.frame = CGRect(x: (size - row) / 2 + CGFloat(index) * (diameter + gap), y: (size - diameter) / 2 + diameter * 0.4,
                               width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
            dot.opacity = 0.3
            layer.addSublayer(dot)
            return dot
        }
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func paint() {
        for dot in dots { dot.backgroundColor = color.cgColor }
    }

    func startAnimating() {
        isAnimating = true
        isHidden = false
        run()
    }

    func stopAnimating() {
        isAnimating = false
        isHidden = true
        halt()
    }

    private func halt() {
        for dot in dots { dot.removeAnimation(forKey: "loading") }
    }

    /// Core Animation drops it when the view leaves the window.
    private func run() {
        halt()
        for (index, dot) in dots.enumerated() {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.toValue = -dot.bounds.height * 0.8
            let light = CABasicAnimation(keyPath: "opacity")
            light.toValue = 1
            for part in [rise, light] {
                part.beginTime = Double(index) * 0.2
                part.duration = 0.3
                part.autoreverses = true
                part.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            let round = CAAnimationGroup()
            round.animations = [rise, light]
            round.duration = 1.15
            round.repeatCount = .infinity
            round.isRemovedOnCompletion = false
            dot.add(round, forKey: "loading")
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if isAnimating, window != nil { run() }
    }
}

/// `LoadingSymbol` for SwiftUI.
struct LoadingSpinner: View {
    var size: CGFloat = 64
    var color: UIColor?

    private struct Ring: UIViewRepresentable {
        let size: CGFloat
        let color: UIColor?

        func makeUIView(context: Context) -> LoadingSymbol {
            let ring = LoadingSymbol(size: size)
            ring.startAnimating()
            return ring
        }

        func updateUIView(_ ring: LoadingSymbol, context: Context) {
            if let color { ring.color = color }
        }
    }

    var body: some View {
        Ring(size: size, color: color).frame(width: size, height: size)
    }
}

/// `liquidGlass`: Liquid Glass — or, Surfaces set to Flat, the app's flat
/// surface (it follows the setting live).
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var untinted = false

    /// Glass is dark in both appearances, its text white: it floats over
    /// pictures as much as over the page.
    func body(content: Content) -> some View {
        // `atvGlass` has had a solid fallback for the slower boxes for a while;
        // this one — which is what the rail, the filter pills, the search bar,
        // the detail icon circles and EVERY unselected season chip actually call
        // — had none. A fifteen-season show meant fourteen live glass capsules
        // in one scroller, and the rail was a full-height live blur that
        // re-composited through its own expand/collapse animation.
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            content.background(FusionMaterials.dialog, in: shape)
                .environment(\.colorScheme, .dark)
        } else if #available(tvOS 26.0, *) {
            content.glassEffect(untinted ? .regular : .regular.tint(AppGlass.surfaceTint), in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// Caption shown BELOW an Apple TV–theme card, OUTSIDE the focus platter.
/// The native `CardButtonStyle` draws its raised platter behind the whole
/// button label, so any caption kept inside the button gets bridged to the
/// artwork by a connecting slab (the "weird square"). Rendering the label as a
/// sibling below the button — the way the real tvOS home screen and TV app do
/// it — keeps the poster a clean tile and the title a free-floating label.
struct ATVCardCaption: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let title: String
    var subtitle: String? = nil
    var width: CGFloat
    /// True while this caption's card is focused: the native platter grows the
    /// artwork downward past the caption's resting gap, so the caption eases
    /// down in step to keep a constant distance from the poster's bottom edge.
    var lowered: Bool = false
    /// How far to drop while lowered — the platter's bottom-edge growth plus
    /// breathing room, so the gap reads clearly at couch distance.
    var dropDistance: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(FusionType.cardTitle)
                .foregroundStyle(CuePalette.textPrimary)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(FusionType.metadata)
                    .foregroundStyle(CuePalette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.top, 4)
        // The drop exists to keep a constant gap as the native platter grows the
        // artwork downward — so it must not happen when the platter is off. With
        // the parallax suppressed (Reduce Motion, or the Apple TV HD's own tier
        // defaults) the caption used to slide 18pt away from a poster that had
        // not moved: an unrequested animation AND a layout bug. It also had no
        // Reduce Motion gate of its own, unlike everything else on the card.
        .offset(y: lowered && perf.motionOn ? dropDistance : 0)
        .animation(perf.motion(FusionMotion.focusEntry), value: lowered)
    }
}

/// A grid poster cell in the app's one look: native platter focus, hold menu,
/// ⏯ straight to the source picker, and the caption easing down while focused
/// so the grown platter never crowds it. Used by the Home grid and Search.
struct GridPosterCell: View {
    @EnvironmentObject private var layout: HomeCatalogSettingsStore
    let item: MetaItem
    let captionWidth: CGFloat
    let onSelect: (MetaItem) -> Void
    var onPlayManually: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    /// Optional external focus tracking (Discover's back-to-top uses it).
    var gridFocus: FocusState<String?>.Binding? = nil
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            button

            ATVCardCaption(
                title: item.name,
                subtitle: item.year,
                width: captionWidth,
                lowered: focused
            )
        }
    }

    @ViewBuilder
    private var button: some View {
        let base = Button {
            onSelect(item)
        } label: {
            PosterCard(item: item)
                .onFocusChange {
                    focused = $0
                    // Honest router note (no handler): a rail exit from a grid
                    // falls back to the engine's pick instead of teleporting
                    // to the last routed ROW the viewer was in.
                    if $0 { ContentFocusRouter.shared.noteFocused(row: "grid") }
                }
        }
        .mediaCardButtonStyle()
        .titleMenu(item)
        .onPlayPauseCommand { onPlayManually(item, nil) }

        if let gridFocus {
            base.focused(gridFocus, equals: item.id)
        } else {
            base
        }
    }
}

/// Card-button chrome: the native tvOS `CardButtonStyle` — the raised platter
/// with the trackpad tilt/wiggle parallax, exactly like home-screen icons.
private struct MediaCardButtonStyleModifier: ViewModifier {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    var onPressChanged: ((Bool) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if perf.motionOn {
            // Native platter: raised card + trackpad tilt/parallax.
            content.buttonStyle(CardButtonStyle())
        } else {
            // Reduce Motion: a scale-only focus. Cards still respond to focus;
            // their own glow/border (drawn off \.isFocused) still shows.
            content.buttonStyle(FlatCardButtonStyle(onPressChanged: onPressChanged))
        }
    }
}

/// Parallax off: focus is a plain scale with no native platter. The card's own
/// focus glow/border still render (they read `\.isFocused`, which this style
/// leaves intact).
struct FlatCardButtonStyle: ButtonStyle {
    var onPressChanged: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, onPressChanged: onPressChanged)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let onPressChanged: ((Bool) -> Void)?

        var body: some View {
            configuration.label
                .focusLift(CueFocus.card, isFocused)
                .cardPressDip(configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    onPressChanged?(pressed)
                }
        }
    }
}

extension View {
    /// Apply to Buttons whose label is a media card (poster / landscape).
    func mediaCardButtonStyle(onPressChanged: ((Bool) -> Void)? = nil) -> some View {
        modifier(MediaCardButtonStyleModifier(onPressChanged: onPressChanged))
    }
}

/// Borderless button wrapper so cards manage their own focus visuals.
struct PlainCardButtonStyle: ButtonStyle {
    /// Reports Select press begin/end so screens can pause state changes that
    /// would re-render mid-hold and break context-menu long presses.
    var onPressChanged: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .cardPressDip(configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                onPressChanged?(pressed)
            }
    }
}

/// The shared Select-press feedback for a card button style: the same dip, the
/// same curve, and **nothing at all** when Reduce Motion is on.
private struct CardPressDip: ViewModifier {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(perf.motionOn && isPressed ? FusionFocus.pressScale : 1)
            .animation(perf.buttonMotion(FusionFocus.pressAnimation), value: isPressed)
    }
}

/// The one focus-motion vocabulary the whole app speaks.
///
/// Every focusable element picks a ROLE here instead of writing its own
/// `.scaleEffect(isFocused ? 1.0x : 1)`: they all go through
/// `View.focusLift(_:_:)` and settle on the same curve.
///
/// Roles differ from ONE ANOTHER on purpose: a 300pt poster and a 72pt
/// settings row should not grow by the same fraction.
///
/// Adding a theme? Don't add scales — reuse these roles and the theme
/// automatically inherits the app's focus behaviour, the "Focus zoom"
/// performance switch and Reduce Motion.
enum CueFocus {
    /// Full-width list rows: settings rows, side-panel rows, dropdown options.
    static let row: CGFloat = 1.02
    /// The default for anything card-shaped: posters, tiles, episode cards,
    /// chips, pills and ordinary buttons.
    static let card: CGFloat = 1.05
    /// Small circular icon controls — trash, reorder, player transport, keypad
    /// keys. Small targets need a larger fraction to read as focused at all.
    static let control: CGFloat = 1.08
    /// Deliberately-large focus targets: profile avatars and their tiles.
    static let avatar: CGFloat = 1.12
    /// Carousel position dots — tiny, so they take the largest scale.
    static let dot: CGFloat = 1.4

    /// The single curve every focus move settles on, app-wide.
    static let animation: Animation = FusionFocus.liftAnimation
}

/// The shared focus lift for a themed card/tile: the theme's own scale, but
/// gated by "Cards spring slightly larger when focused" + Reduce Motion, and
/// animated on one curve so a focus move settles at the same rate in every
/// theme. The `.animation` also carries the card's focus ring / colour change,
/// so under Reduce Motion those snap instead of easing.
private struct FocusLift: ViewModifier {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let scale: CGFloat
    let focused: Bool
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .scaleEffect(perf.focusScale(scale, focused))
            .animation(perf.motion(animation), value: focused)
    }
}

extension View {
    /// Apply inside a card `ButtonStyle.makeBody` to get the shared press dip.
    func cardPressDip(_ isPressed: Bool) -> some View {
        modifier(CardPressDip(isPressed: isPressed))
    }

    /// Replaces a hand-rolled `.scaleEffect(focused ? x : 1)` +
    /// `.animation(…, value: focused)` pair, so everything obeys Reduce Motion.
    func focusLift(_ scale: CGFloat, _ focused: Bool,
                   animation: Animation = FusionFocus.liftAnimation) -> some View {
        modifier(FocusLift(scale: scale, focused: focused, animation: animation))
    }
}

// MARK: - Badges & meta

/// Small "watched" checkmark chip shown on poster/landscape cards.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 20, weight: .heavy))
            .foregroundStyle(.white)
            .padding(9)
            .background(Circle().fill(CuePrimitives.success))
            // The white ring provides the contrast; no shadow — each shadow is
            // an offscreen pass, and one rides on EVERY watched card in a row.
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
    }
}

/// A row of MDBList source ratings (IMDb, TMDB, RT, Metacritic, …) as
/// chips in the title badge's shape (`TitleBadge`), so they sit with it as
/// one row of equals: the source's short name in its brand colour, then the
/// score, the outline in the brand colour too — colour here is information
/// (which source), the one place the app uses brand colour.
struct MDBListRatingsRow: View {
    let entries: [MDBListRatingEntry]
    /// Chips onto further lines when they don't fit (About), not cut.
    var wraps = false

    /// The row's entries: every rating from MDBList, IMDb's too, the same
    /// on every screen (decided 2026-11-24: a catalog's or TMDB's score
    /// under IMDb's mark made Home and Details disagree); none without
    /// MDBList, or where Settings turned ratings off (`onDetails`: on
    /// Details).
    static func entries(_ ratings: MDBListRatings?, settings: MDBListSettings,
                        onDetails: Bool) -> [MDBListRatingEntry] {
        guard settings.showsRatings(onDetails: onDetails) else { return [] }
        return ratings?.entries(settings: settings) ?? []
    }

    private func chip(_ entry: MDBListRatingEntry) -> some View {
        RatingChip(provider: entry.provider, score: entry.text)
    }

    var body: some View {
        if wraps {
            WrapRow(spacing: RatingChip.spacing, lineSpacing: 10) {
                ForEach(entries) { chip($0) }
            }
        } else {
            HStack(spacing: RatingChip.spacing) {
                ForEach(entries) { chip($0) }
            }
        }
    }
}

/// A rating source's colour, after its own branding (its name is
/// its mark — `RatingMark`).
struct RatingBadgeStyle {
    let fill: AnyShapeStyle
}

extension MDBListProvider {
    var badgeStyle: RatingBadgeStyle {
        func rgb(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
        }
        switch self {
        case .imdb:
            return .init(fill: AnyShapeStyle(CuePrimitives.imdb))
        case .trakt:
            return .init(fill: AnyShapeStyle(rgb(0xED1C24)))
        case .tmdb:
            // TMDB's green-to-blue gradient.
            return .init(fill: AnyShapeStyle(LinearGradient(
                colors: [rgb(0x90CEA1), rgb(0x01B4E4)],
                startPoint: .leading, endPoint: .trailing)))
        case .letterboxd:
            // Its middle dot's green.
            return .init(fill: AnyShapeStyle(rgb(0x00E054)))
        case .tomatoes:
            return .init(fill: AnyShapeStyle(rgb(0xFA320A)))
        case .audience:
            // The popcorn's yellow (its icon's; was #FFB600, too orange).
            return .init(fill: AnyShapeStyle(rgb(0xFED500)))
        case .myanimelist:
            // MyAnimeList's blue (#2E51A2) lightened to read as an outline
            // on dark pictures, still dark enough under the plate's white
            // letters (tried: #6E8FE0 — the outline, the plate its own blue).
            return .init(fill: AnyShapeStyle(rgb(0x4F72CC)))
        case .metacritic:
            // Its ring's yellow (tried: its score scale, green 61+ / yellow /
            // red — not its look).
            return .init(fill: AnyShapeStyle(rgb(0xFFCC34)))
        }
    }
}

/// One rating: the source's mark, then its score as plain text in the
/// facts line's style — no box (outlined chips in the source's colour were
/// the look before: they read as stickers). Without a score the mark alone
/// (Settings' Order row, a preview of the order).
struct RatingChip: View {
    let provider: MDBListProvider
    var score: String? = nil
    /// Between one rating and the next, and the status before them.
    static let spacing: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            RatingMark(provider: provider)
            if let score {
                Text(score)
                    .font(Font(FixedFocusText.infoFont(FixedFocusMetrics.textSize)))
                    .foregroundStyle(CueInk.primary)
            }
        }
        .frame(height: 30)
    }
}

/// A rating source's name on its chip: its logo cut down to a shape or
/// two, about 14 pt, in its own colours — a wordmark on its plate, the
/// others their emblem (tried: the names in their colours — "LBXD", "RT",
/// "MC" meant little; Rotten Tomatoes' two in two small lines).
struct RatingMark: View {
    let provider: MDBListProvider
    /// Every mark's height.
    static let size: CGFloat = 18
    /// The emblems are drawn on a 14 pt grid, scaled up to `size`.
    private static func grid(_ frame: CGSize, _ context: inout GraphicsContext) -> CGSize {
        let k = frame.height / 14
        context.scaleBy(x: k, y: k)
        return CGSize(width: frame.width / k, height: 14)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
    private static let tomatoRed = rgb(0xFA320A)

    var body: some View {
        switch provider {
        case .imdb: plate("IMDb", text: .black)
        case .tmdb: plate("TMDB", text: Self.rgb(0x0D253F))
        case .myanimelist: plate("MAL", text: .white)
        case .trakt: trakt
        case .letterboxd: dots
        case .tomatoes: tomato
        case .audience: bucket
        case .metacritic: metacritic
        }
    }

    /// The wordmark, dark on its colour (MAL's white on its blue).
    private func plate(_ name: String, text: Color) -> some View {
        Text(name)
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(text)
            .padding(.horizontal, 5)
            .frame(height: Self.size)
            .background(provider.badgeStyle.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// Trakt: its red disc, a white ring inside.
    private var trakt: some View {
        Canvas { context, frame in
            var context = context
            let size = Self.grid(frame, &context)
            let disc = CGRect(origin: .zero, size: size)
            context.fill(Path(ellipseIn: disc), with: .color(Self.rgb(0xED1C24)))
            context.stroke(Path(ellipseIn: disc.insetBy(dx: 3.25, dy: 3.25)),
                           with: .color(.white), lineWidth: 1.5)
        }
        .frame(width: Self.size, height: Self.size)
    }

    /// Letterboxd: its three dots, orange, green, blue, overlapping in its
    /// dark slate.
    private var dots: some View {
        let colours = [Self.rgb(0xFF8000), Self.rgb(0x00E054), Self.rgb(0x40BCF4)]
        let diameter: CGFloat = 16, step: CGFloat = 14   // the logo's ~88 %
        return Canvas { context, _ in
            let dots = (0..<3).map { i in
                Path(ellipseIn: CGRect(x: CGFloat(i) * step, y: 0, width: diameter, height: diameter))
            }
            for (dot, colour) in zip(dots, colours) { context.fill(dot, with: .color(colour)) }
            for i in 0..<2 {
                context.fill(dots[i].intersection(dots[i + 1]), with: .color(Self.rgb(0x556678)))
            }
        }
        .frame(width: 2 * step + diameter, height: diameter)
    }

    /// Rotten Tomatoes: the tomato, a green leaf on top.
    private var tomato: some View {
        Canvas { context, frame in
            var context = context
            let size = Self.grid(frame, &context)
            context.fill(Path(ellipseIn: CGRect(x: 0, y: 1.5, width: size.width, height: size.height - 1.5)),
                         with: .color(Self.tomatoRed))
            var leaf = Path()
            leaf.move(to: CGPoint(x: size.width / 2 - 4.5, y: 1.5))
            leaf.addQuadCurve(to: CGPoint(x: size.width / 2 + 4.5, y: 1.5),
                              control: CGPoint(x: size.width / 2, y: -1.5))
            leaf.addQuadCurve(to: CGPoint(x: size.width / 2 - 4.5, y: 1.5),
                              control: CGPoint(x: size.width / 2, y: 5.5))
            context.fill(leaf, with: .color(Self.rgb(0x3FB34F)))
        }
        .frame(width: Self.size, height: Self.size)
    }

    /// Popcornmeter: the bucket, red and white stripes, the popcorn's
    /// yellow over its rim.
    private var bucket: some View {
        Canvas { context, frame in
            var context = context
            let size = Self.grid(frame, &context)
            let w = size.width, h = size.height
            var pail = Path()
            pail.move(to: CGPoint(x: 0, y: 5.5))
            pail.addLine(to: CGPoint(x: w, y: 5.5))
            pail.addLine(to: CGPoint(x: w - 2, y: h))
            pail.addLine(to: CGPoint(x: 2, y: h))
            pail.closeSubpath()
            context.fill(pail, with: .color(Color.white.opacity(0.9)))
            var stripes = context
            stripes.clip(to: pail)
            for x in stride(from: CGFloat(0), to: w, by: 4) {
                stripes.fill(Path(CGRect(x: x, y: 0, width: 2, height: h)), with: .color(Self.tomatoRed))
            }
            for (x, y, d) in [(0.0, 2.0, 5.0), (3.5, 0.0, 5.5), (7.0, 2.0, 5.0)] as [(CGFloat, CGFloat, CGFloat)] {
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                             with: .color(Self.rgb(0xFED500)))
            }
        }
        .frame(width: 12 * Self.size / 14, height: Self.size)
    }

    /// Metacritic: its white "m" on black in a yellow ring.
    private var metacritic: some View {
        Canvas { context, frame in
            var context = context
            let size = Self.grid(frame, &context)
            let disc = CGRect(origin: .zero, size: size)
            context.fill(Path(ellipseIn: disc), with: .color(Self.rgb(0xFFCC34)))
            context.fill(Path(ellipseIn: disc.insetBy(dx: 1.75, dy: 1.75)), with: .color(.black))
            context.draw(Text("m").font(.system(size: 10, weight: .heavy)).foregroundColor(.white),
                         at: CGPoint(x: size.width / 2, y: size.height / 2 - 0.5))
        }
        .frame(width: Self.size, height: Self.size)
    }
}

// MARK: - Loading / error states

/// An invisible 1pt focusable. Put one in any state that would otherwise have
/// NO focusable view (loading screens, QR sign-in pages): with nothing focused
/// the tvOS focus engine has no responder, so `.onExitCommand` never fires and
/// a Menu press falls through to the system — suspending the app at a root, or
/// bypassing a page's own Back handling.
struct FocusAnchor: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .accessibilityHidden(true)
    }
}

struct CueLoadingView: View {
    var label: String = "Loading"
    /// Hold focus while this is the only thing on screen (see FocusAnchor).
    var holdsFocus: Bool = false

    var body: some View {
        VStack(spacing: CueSpacing.lg) {
            if holdsFocus { FocusAnchor() }
            LoadingSpinner()
            Text(label)
                .font(.system(size: 24))
                .foregroundStyle(CuePalette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CueEmptyState: View {
    let icon: String
    let title: String
    let message: String
    /// Hold focus while this is the only thing on a PUSHED screen: with
    /// nothing focusable, Menu never reaches `.onExitCommand` and suspends
    /// the app instead of popping the page (see FocusAnchor).
    var holdsFocus: Bool = false

    var body: some View {
        VStack(spacing: CueSpacing.md) {
            if holdsFocus { FocusAnchor() }
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundStyle(CuePalette.textTertiary)
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(CuePalette.textPrimary)
            Text(message)
                .font(.system(size: 23))
                .foregroundStyle(CuePalette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Formatting helpers

// MARK: - Toasts (§54)

/// Lightweight app-wide toast center for browsing-side confirmations
/// (Added to Library, Marked Watched, Rating Saved…). Separate from the
/// player's own `toast`. Auto-dismisses after `FusionMotion.toastVisibleSeconds`.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?
    @Published var icon: String?
    private var task: Task<Void, Never>?

    func show(_ message: String, icon: String? = nil) {
        withAnimation(FusionMotion.toastEnter) {
            self.message = message
            self.icon = icon
        }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(FusionMotion.toastVisibleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(FusionMotion.toastExit) { self?.message = nil }
        }
    }
}

/// Lower-center toast (§54): dark glass pill, white text, optional accent icon.
/// Never takes focus. Hosted at the app root.
struct FusionToastHost: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let message = center.message {
                HStack(spacing: CueSpacing.sm) {
                    if let icon = center.icon {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(CuePalette.secondary)
                    }
                    Text(message)
                        .font(FusionType.button)
                        .foregroundStyle(CueInk.primary)
                }
                .padding(.horizontal, CueSpacing.xl)
                .padding(.vertical, CueSpacing.md)
                .liquidGlass(in: Capsule())
                .padding(.bottom, CueSpacing.huge)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared themed card row

// NOTE: `ThemedCardRow` lived here — "the horizontal card strip every themed
// home builds" — along with `View.focusExpand` and the `FocusExpand` modifier it
// drove. It had ZERO call sites: the 210->560pt focused-card growth belonged to
// the themes that were retired in the glass redesign, and the four rows that
// remain (HomePosterRow, ContinueWatchingRow, and the two collection rows) each
// build their own strip. `FusionMotion.rowExpand`, whose comment recorded a real
// fix for a spring that visibly wobbled, went with it.

// MARK: - Shared content-rating lookup

extension View {
    /// Keep `rating` in sync with the TMDB certification ("TV-MA", "PG-13") for
    /// the item a hero is showing.
    ///
    /// Every hero in the app needed this and each carried its own copy of the
    /// same `loadContentRating()` — seven of them, differing only in how they
    /// reached the item. The staleness guard each one hand-rolled ("is this
    /// still the item I fetched for?") is what `.task(id:)` already does: it
    /// cancels the in-flight fetch when the id changes, so a slow lookup can't
    /// land on the next title.
    ///
    /// Collections have no certification and are skipped.
    func contentRating(for item: MetaItem?, into rating: Binding<String?>) -> some View {
        task(id: item?.id) {
            guard let item, item.type != "collection" else {
                rating.wrappedValue = nil
                return
            }
            let value = await TMDBService.contentRating(imdbID: item.id, type: item.type)
            guard !Task.isCancelled else { return }
            rating.wrappedValue = value
        }
    }
}

struct WrapRow: Layout {
    var spacing: CGFloat = 20
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                widest = max(widest, x)
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(max(widest, x), maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache _: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                          anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The image cache's bytes and its copies by picture, kept as it adds and
/// evicts (NSCache says neither).
private final class CostLedger: NSObject, NSCacheDelegate, @unchecked Sendable {
    /// One decoded copy of a picture in memory: its key and pixels.
    struct Copy { let key: String; let width: Int; let height: Int; let cost: Int }
    private let lock = NSLock()
    private var byImage: [ObjectIdentifier: (url: String, copy: Copy)] = [:]
    private var byURL: [String: [Copy]] = [:]
    private var sum = 0
    var total: Int { lock.lock(); defer { lock.unlock() }; return sum }

    func add(_ image: UIImage, _ cost: Int, key: String) {
        lock.lock(); defer { lock.unlock() }
        removeLocked(ObjectIdentifier(image))
        let url = ImageCache.url(ofKey: key)
        let copy = Copy(key: key, width: Int(image.size.width * image.scale),
                        height: Int(image.size.height * image.scale), cost: cost)
        byImage[ObjectIdentifier(image)] = (url, copy)
        byURL[url, default: []].append(copy)
        sum += cost
    }

    func remove(_ image: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        removeLocked(ObjectIdentifier(image))
    }

    private func removeLocked(_ id: ObjectIdentifier) {
        guard let (url, copy) = byImage.removeValue(forKey: id) else { return }
        sum -= copy.cost
        byURL[url]?.removeAll { $0.key == copy.key }
        if byURL[url]?.isEmpty == true { byURL[url] = nil }
    }

    func copies(of url: String) -> [Copy] {
        lock.lock(); defer { lock.unlock() }
        return byURL[url] ?? []
    }

    /// Pictures held at more than one size, and those copies' bytes.
    func duplicates() -> (pictures: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let many = byURL.values.filter { $0.count > 1 }
        return (many.count, many.reduce(0) { $0 + $1.reduce(0) { $0 + $1.cost } - ($1.map(\.cost).max() ?? 0) })
    }

    /// The pictures held at more than one size, each copy's pixels.
    func duplicateSizes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return byURL.filter { $0.value.count > 1 }.map { url, copies in
            (url.split(separator: "/").last.map(String.init) ?? url) + "  "
                + copies.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
        }
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        remove(obj as AnyObject)
    }
}

/// One line of text that, cut short, fades out over its end instead of
/// "…" (`EndFadeLabel`'s SwiftUI side). Its ideal size stays the whole
/// line, so `ViewThatFits` still sees what it needs.
extension View {
    func endFade() -> some View { modifier(EndFade()) }
}

private struct EndFade: ViewModifier {
    @State private var natural: CGFloat = 0
    @State private var shown: CGFloat = 0

    func body(content: Content) -> some View {
        let cut = natural > shown + 0.5 && shown > 0
        EndFadeLayout {
            content
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shown = $0 }
        .clipped()
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: cut ? max(0, 1 - EndFadeLabel.run / max(shown, 1)) : 1),
                .init(color: cut ? .clear : .black, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// Its one view at its whole width, shown in as much of it as there's room for.
private struct EndFadeLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let whole = view.sizeThatFits(.unspecified)
        return CGSize(width: min(whole.width, proposal.width ?? whole.width), height: whole.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}
