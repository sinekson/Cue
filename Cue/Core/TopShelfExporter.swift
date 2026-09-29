import Foundation
import TVServices
import UIKit
import CryptoKit

/// Writes the Continue Watching list AND the Library (watchlist) into the
/// shared app-group container so the Top Shelf extension can render them on
/// the tvOS home screen — Continue Watching as landscape cards, the Library
/// as portrait posters beside it (the Crunchyroll layout). Continue Watching
/// is exported by ProgressStore whenever progress persists; the Library by
/// LibraryStore whenever it changes. Both snapshots are tiny and written
/// off-main.
///
/// Sideload caveat: if the signing tool strips the app-group entitlement,
/// `containerURL` is nil and this is a silent no-op — the app works, the
/// shelf just stays empty.
enum TopShelfExporter {
    /// Mirrored by TopShelfProvider.Entry in the extension target — keep the
    /// fields/keys in sync.
    struct Entry: Codable {
        let id: String
        let type: String
        let title: String
        let subtitle: String?
        let imageURL: String?
        /// How far in, 0...1 — drawn as the bar across the bottom of the card.
        /// Optional so a snapshot written by an older build still decodes; it
        /// reads back as nil and the card simply has no bar.
        var progress: Double? = nil
        /// What the shelf shows under the card: the EPISODE title for a
        /// series (falling back to "S1:E3" when it has none). Nil for movies
        /// and library items, which show `title`. Optional so older
        /// snapshots still decode.
        var caption: String? = nil
        /// Raw art for the card renderer (see TopShelfCardRenderer): the
        /// show/movie BACKDROP for the landscape card, the POSTER for the
        /// portrait ones. Optional so older snapshots still decode.
        var backdropURL: String? = nil
        var posterURL: String? = nil
        /// Episode coordinates, so the renderer can fetch the episode's TMDB
        /// still in full resolution (see `EpisodeStill`).
        var season: Int? = nil
        var episode: Int? = nil
        /// "40m left", drawn into the card beside the bar (as on Home).
        /// Optional so older snapshots still decode (the extension ignores
        /// it — it's only for the app's renderer).
        var timeLeft: String? = nil
    }

    /// Build the export entries on the caller's (main) side — cheap — so the
    /// disk write can happen on a background task with plain value data.
    static func entries(from progresses: [WatchProgress]) -> [Entry] {
        progresses.prefix(10).map { p in
            var subtitle: String?
            var caption: String?
            if let s = p.season, let e = p.episode {
                subtitle = "S\(s):E\(e)"
                caption = subtitle
                if let t = p.episodeTitle, !t.isEmpty {
                    subtitle! += " · \(t)"
                    caption = t
                }
            }
            return Entry(
                id: p.metaID,
                type: p.type,
                title: p.name,
                subtitle: subtitle,
                // Wide art to match the .hdtv shape: episode still, then
                // backdrop, then poster as a last resort.
                imageURL: p.episodeThumbnail ?? p.background ?? p.poster,
                // `fraction` is already position/duration guarded against a
                // zero duration; clamp anyway because playbackProgress is
                // documented as 0...1 and a row restored from another device
                // can carry a position past its duration.
                progress: min(max(p.fraction, 0), 1),
                caption: caption,
                // Wide card fallback when there's no TMDB episode still (the
                // renderer tries that first): the show/movie backdrop at full
                // resolution, then whatever still the add-on supplied.
                backdropURL: sharper(p.background, size: "original")
                    ?? sharper(p.episodeThumbnail ?? p.poster, size: "original"),
                posterURL: sharper(p.poster ?? p.background, size: "w780"),
                season: p.season,
                episode: p.episode,
                timeLeft: p.remainingTimeText.map { "\($0) left" }
            )
        }
    }

    /// The stored art URLs are often TMDB's small renditions (w300/w500),
    /// which is what made the shelf cards look soft. TMDB serves every size
    /// from the same path, so ask for a bigger one. Other hosts: unchanged.
    /// `size` must be one TMDB offers for that kind of image: posters go up
    /// to w780, stills and backdrops use "original" (stills have no w1280).
    static func sharper(_ url: String?, size: String) -> String? {
        guard let url, url.contains("image.tmdb.org") else { return url }
        return url.replacingOccurrences(of: "/t/p/(w[0-9]+|original)/", with: "/t/p/\(size)/",
                                        options: .regularExpression)
    }

    /// Library → Top Shelf entries, newest first (the Library grid's order).
    /// Portrait art: the poster, with the backdrop as a last resort.
    static func libraryEntries(from items: [SavedLibraryItem]) -> [Entry] {
        items.prefix(15).map { item in
            Entry(id: item.id, type: item.type, title: item.name,
                  subtitle: nil, imageURL: item.poster ?? item.background)
        }
    }

    @MainActor private static var librarySequence: UInt64 = 0

    /// Export the Library. Called by LibraryStore on every change.
    @MainActor static func exportLibrary(_ items: [SavedLibraryItem]) {
        let entries = libraryEntries(from: items)
        librarySequence += 1
        let ticket = librarySequence
        Task.detached(priority: .utility) {
            await TopShelfWriter.shared.writeLibrary(entries, sequence: ticket)
        }
    }

    /// Whether the profile whose data would be exported is PIN-locked.
    ///
    /// The Top Shelf draws on the tvOS home screen — OUTSIDE the app, before
    /// the "Who's watching?" gate ever appears. Exporting a locked profile's
    /// Continue Watching would put the titles, episode names and artwork that
    /// the PIN exists to hide in front of anyone who walks up to the TV, with
    /// no PIN asked for. Read straight from the profile blob rather than
    /// taking a ProfileStore dependency: this runs on the persist path, off
    /// the main actor, where the store isn't reachable.
    private static var activeProfileIsLocked: Bool {
        struct Row: Decodable { let id: Int; let pinEnabled: Bool? }
        let defaults = UserDefaults.standard
        let active = defaults.object(forKey: "cue.profiles.active") as? Int ?? 1
        guard let data = defaults.data(forKey: "cue.profiles.v1"),
              let rows = try? JSONDecoder().decode([Row].self, from: data)
        else { return false }
        return rows.first { $0.id == active }?.pinEnabled ?? false
    }

    /// Monotonic ticket for shelf writes, taken on the main actor at each
    /// call site so the ORDER the app decided on is the order the file sees.
    /// Three writers used to race unordered (the periodic persister, the
    /// profile-switch reload and the PIN refresh), and a profile switch could
    /// have the previous profile's queued write land last — its titles on the
    /// home screen under the new profile.
    @MainActor private static var sequence: UInt64 = 0
    @MainActor static func nextSequence() -> UInt64 {
        sequence += 1
        return sequence
    }

    /// Ordered write: a ticket older than the last one written is dropped.
    static func writeOrdered(_ entries: [Entry], sequence: UInt64) async {
        await TopShelfWriter.shared.write(entries, sequence: sequence)
    }

    static let continueFile = "topshelf.json"
    static let libraryFile = "topshelf-library.json"

    /// Persist to the shared container. Safe to call from any thread.
    static func write(_ entries: [Entry], to fileName: String = continueFile) {
        guard let file = AppGroupResolver.sharedFile(fileName) else {
            NSLog("[TopShelf] no shared container — app group unavailable")
            return
        }
        // A locked profile writes an EMPTY shelf rather than skipping the
        // write. Skipping would leave whatever the previous profile exported
        // sitting on the home screen, which is the leak being closed.
        let payload = activeProfileIsLocked ? [] : entries
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Reported, not swallowed: a `try?` here is what let the unwritable
        // container root go unnoticed for as long as it did.
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("[TopShelf] snapshot write failed at %@: %@",
                  file.path, String(describing: error))
        }
        // The scheme the extension must deep-link on, published by the ONE
        // side that knows it for certain: `cue` is claimed by every other
        // sideload of this app on the box, so a card opened on the shelf could
        // land in one of those instead of here (the same collision that sent
        // Infuse's callback to NuvioTVOS). The extension cannot derive it —
        // its own bundle id is not what the app registered — so it is written
        // next to the snapshot.
        if let schemeFile = AppGroupResolver.sharedFile("topshelf-scheme.txt") {
            try? Data(AppCallbackScheme.value.utf8).write(to: schemeFile, options: .atomic)
        }
        // Ask tvOS to reload the shelf now, instead of whenever it next
        // decides to — otherwise a title added to the Library (or a finished
        // episode) could sit wrong on the home screen for a long while.
        DispatchQueue.main.async {
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }
}

/// Serialises Top Shelf snapshot writes and enforces their ticket order.
private actor TopShelfWriter {
    static let shared = TopShelfWriter()
    private var lastSequence: UInt64 = 0
    private var lastLibrarySequence: UInt64 = 0

    func write(_ entries: [TopShelfExporter.Entry], sequence: UInt64) async {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        // Continue Watching cards are rendered by the app (art + progress
        // pill baked in): ALL as landscape cards — the episode still, else
        // the backdrop. tvOS's own progress bar sits flush on the card's
        // bottom edge and can't be moved, so it isn't used.
        var rendered = entries
        var keep: Set<String> = []
        for index in rendered.indices {
            let entry = rendered[index]
            // The card shows the EPISODE — its TMDB still in full
            // resolution, the same image the app's Continue Watching uses.
            var wideSource = entry.backdropURL
            if let still = await EpisodeStill.url(
                metaID: entry.id, type: entry.type, season: entry.season, episode: entry.episode) {
                wideSource = still
            }
            guard let source = wideSource ?? entry.posterURL,
                  let card = await TopShelfCardRenderer.card(
                      from: source, landscape: true, progress: entry.progress ?? 0,
                      episode: entry.season.flatMap { s in entry.episode.map { "S\(s):E\($0)" } },
                      timeLeft: entry.timeLeft)
            else { continue }   // render failed: keep the remote art + system bar
            keep.insert(card.lastPathComponent)
            rendered[index] = TopShelfExporter.Entry(
                id: entry.id, type: entry.type, title: entry.title,
                subtitle: entry.subtitle, imageURL: card.absoluteString,
                progress: nil,   // baked into the image instead
                caption: entry.caption,
                backdropURL: entry.backdropURL, posterURL: entry.posterURL,
                season: entry.season, episode: entry.episode, timeLeft: entry.timeLeft)
        }
        // A newer snapshot arrived while this one was rendering: it wins.
        guard sequence == lastSequence else { return }
        TopShelfExporter.write(rendered)
        TopShelfCardRenderer.removeCards(except: keep)
    }

    func writeLibrary(_ entries: [TopShelfExporter.Entry], sequence: UInt64) {
        guard sequence > lastLibrarySequence else { return }
        lastLibrarySequence = sequence
        TopShelfExporter.write(entries, to: TopShelfExporter.libraryFile)
    }
}

/// Renders Continue Watching cards for the Top Shelf: the artwork with a
/// tvOS-style progress pill (grey track, white fill) baked in, inset from
/// the card's edges. Files live in the shared app-group folder, named by
/// art + shape + 5% progress step, so an unchanged card is never re-rendered
/// and a changed one gets a NEW file name (tvOS caches shelf images by URL).
enum TopShelfCardRenderer {
    /// Rendered at full 1080p / a tall poster so nothing is upscaled on 4K.
    static let landscapeSize = CGSize(width: 1920, height: 1080)
    static let portraitSize = CGSize(width: 600, height: 900)
    private static let prefix = "shelf-card-"

    static func card(from source: String, landscape: Bool, progress: Double,
                     episode: String? = nil, timeLeft: String? = nil) async -> URL? {
        // 5% steps; anything started shows at least one step.
        let clamped = min(max(progress, 0), 1)
        let bucket = clamped > 0 ? max(Int((clamped * 20).rounded()), 1) : 0
        // The drawn text is part of the card's identity too (a new name for
        // new text — tvOS caches shelf images by URL).
        let key = "\(source)|\(episode ?? "")|\(timeLeft ?? "")"
        let digest = SHA256.hash(data: Data(key.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = "\(prefix)v4-\(digest)-\(landscape ? "l" : "p")-\(bucket)\(clamped > 0.02 ? "" : "n").jpg"
        guard let file = AppGroupResolver.sharedFile(name) else { return nil }
        if FileManager.default.fileExists(atPath: file.path) { return file }

        // Disk cache first (the app has usually shown this art already).
        var data = await ImageCache.shared.diskData(for: source)
        if data == nil, let url = URL(string: source) {
            data = try? await ImageCache.shared.download(url)
        }
        let size = landscape ? landscapeSize : portraitSize
        guard let data,
              let image = ImageCache.decodeDownsampled(data, budget: max(size.width, size.height)),
              let jpeg = render(image, size: size, progress: Double(bucket) / 20,
                                started: clamped > 0.02, episode: episode, timeLeft: timeLeft)
        else { return nil }
        do {
            try jpeg.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// The Home Continue Watching card's state line, in the Home card's
    /// proportions (746×420pt there): "S1:E1 ▬▬▬░░ 40m left", or — not
    /// started — "S1:E1 … Up Next" with no bar.
    private enum Line {
        static let inset: CGFloat = 28 / 746.7      // of the width
        static let bottom: CGFloat = 22 / 420       // of the height
        static let barHeight: CGFloat = 10 / 420
        static let textSize: CGFloat = 22 / 420
        static let gap: CGFloat = 14 / 746.7
        static let footStart: CGFloat = 0.4
        static let footOpacity: CGFloat = 0.7
    }

    /// `started`: Home's rule (over 2%) — the bar; else "Up Next".
    private static func render(_ image: UIImage, size: CGSize, progress: Double, started: Bool,
                               episode: String?, timeLeft: String?) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { ctx in
            // Artwork, aspect-FILL.
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - drawn.width) / 2,
                                  y: (size.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))

            // The dark foot, as on Home, so the line reads on bright art.
            let cg = ctx.cgContext
            let colors = [UIColor.black.withAlphaComponent(0).cgColor,
                          UIColor.black.withAlphaComponent(Line.footOpacity).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient,
                                      start: CGPoint(x: 0, y: size.height * Line.footStart),
                                      end: CGPoint(x: 0, y: size.height), options: [])
            }

            let inset = size.width * Line.inset
            let barHeight = max(size.height * Line.barHeight, 8)
            let gap = size.width * Line.gap
            let centerY = size.height - size.height * Line.bottom - barHeight / 2
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = size.height * 0.014
            shadow.shadowOffset = CGSize(width: 0, height: 2)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.height * Line.textSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .shadow: shadow
            ]
            /// Draws `text` with its left edge at `x`, centred on the line;
            /// returns its width.
            @discardableResult
            func draw(_ text: String, x: CGFloat) -> CGFloat {
                let string = NSAttributedString(string: text, attributes: attributes)
                let textSize = string.size()
                string.draw(at: CGPoint(x: x, y: centerY - textSize.height / 2))
                return textSize.width
            }

            var x = inset
            guard started else {
                // Not started: "S1:E1 … Up Next" (episode left, status
                // right — as on Home), no bar.
                if let episode { draw(episode, x: x) }
                let status = "Up Next"
                let width = NSAttributedString(string: status, attributes: attributes).size().width
                draw(status, x: size.width - inset - width)
                return
            }
            if let episode { x += draw(episode, x: x) + gap }
            var barEnd = size.width - inset
            if let timeLeft {
                let width = NSAttributedString(string: timeLeft, attributes: attributes).size().width
                draw(timeLeft, x: barEnd - width)
                barEnd -= width + gap
            }
            let track = CGRect(x: x, y: centerY - barHeight / 2,
                               width: max(barEnd - x, barHeight), height: barHeight)
            UIColor.white.withAlphaComponent(0.3).setFill()
            UIBezierPath(roundedRect: track, cornerRadius: barHeight / 2).fill()
            var fill = track
            fill.size.width = max(track.width * progress, barHeight)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: fill, cornerRadius: barHeight / 2).fill()
        }
        return rendered.jpegData(compressionQuality: 0.92)
    }

    /// Delete old cards so the shared folder doesn't fill up over time.
    static func removeCards(except keep: Set<String>) {
        guard let dir = AppGroupResolver.sharedFile("x")?.deletingLastPathComponent(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        for file in files where file.hasPrefix(prefix) && !keep.contains(file) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }
}

/// The episode's still from TMDB, in full resolution. The stills stored with
/// Continue Watching come from whichever add-on served the episode list and
/// are often small (or missing); TMDB has a consistent, sharp one for
/// practically every episode. Needs a TMDB key; TMDBService caches seasons.
enum EpisodeStill {
    static func url(metaID: String, type: String, season: Int?, episode: Int?) async -> String? {
        guard TMDBService.hasAPIKey, let season, let episode else { return nil }
        let extras = await TMDBService.seasonEpisodes(imdbID: metaID, type: type, season: season)
        return TMDBService.originalSize(extras[episode]?.still)
    }
}
