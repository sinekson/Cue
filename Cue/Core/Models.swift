import Foundation

// MARK: - UserDefaults blob compression

/// Compression for the content stores' UserDefaults blobs (watched history,
/// the library).
///
/// NSUserDefaults on tvOS aborts the process once the app's domain crosses
/// roughly 1 MB — `__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`,
/// observed on a real box at ~984 KB — and these two stores grow with the
/// viewer's library: a long history is tens of thousands
/// of rows of highly repetitive JSON, which is exactly the shape zlib crushes
/// (the add-on list has shipped this way since v8, 18x on real data). Without
/// it, importing a large library makes the very next `save()` abort — the app
/// "crashes constantly when connected" and can never settle.
///
/// Backward compatible by magic: anything without the prefix is plain JSON
/// from an older build and is returned untouched, so the reader accepts both
/// and a downgrade simply re-saves plain.
enum StoreBlob {
    static let magic = Data([0x4F, 0x41, 0x5A, 0x31])   // "OAZ1"

    /// Compressed, behind the magic — or the plain JSON when compression
    /// fails, which `inflated` reads just as happily.
    static func deflated(_ json: Data) -> Data {
        guard let squeezed = try? (json as NSData).compressed(using: .zlib) as Data else { return json }
        return magic + squeezed
    }

    /// The JSON back out. Anything without the magic is returned untouched.
    static func inflated(_ stored: Data) -> Data {
        guard stored.starts(with: magic),
              let json = try? (Data(stored.dropFirst(magic.count)) as NSData)
                .decompressed(using: .zlib) as Data
        else { return stored }
        return json
    }

    /// Compress any key under `prefixes` still stored uncompressed.
    ///
    /// Runs at launch, BEFORE any other write, for the same reason
    /// `AddonManager.reclaimUncompressedStorage` exists: on a box already past
    /// the CFPreferences abort threshold, the first unrelated write (the rename
    /// migration, a store save) aborts the process and the app crash-loops, so
    /// it never reaches the `save()` that would compress. This is a REDUCING
    /// write, which CFPreferences accepts, so it breaks the loop. Lossless —
    /// the same JSON, just compressed. BOTH namespaces, because the rename
    /// migration copies an oversized `nuvio.*` blob into `cue.*` and that
    /// copy would abort the domain this is meant to shrink.
    static func reclaim(prefixes: [String], in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where prefixes.contains(where: key.hasPrefix) {
            guard let stored = defaults.data(forKey: key),
                  !stored.starts(with: magic) else { continue }
            let squeezed = deflated(stored)
            guard squeezed.count < stored.count else { continue }
            defaults.set(squeezed, forKey: key)
            NSLog("[CueStore] reclaimed %@: %d → %d bytes", key, stored.count, squeezed.count)
        }
    }
}

// MARK: - Stremio addon manifest

struct AddonManifest: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let logo: String?
    let types: [String]?
    let idPrefixes: [String]?
    let catalogs: [ManifestCatalog]?
    let resources: [ManifestResource]?
    let behaviorHints: BehaviorHints?

    /// The manifest's hints: `configurable` — the add-on has a settings page
    /// (at its manifest URL with `manifest.json` → `configure`, the Stremio
    /// convention; see `InstalledAddon.configureURL`).
    struct BehaviorHints: Codable, Hashable {
        var configurable: Bool?
        var configurationRequired: Bool?
    }

    var isConfigurable: Bool {
        behaviorHints?.configurable == true || behaviorHints?.configurationRequired == true
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, types, idPrefixes, catalogs, resources, behaviorHints
    }

    /// Tolerant decode: real-world manifests routinely bend the spec (missing
    /// name, numeric versions, odd catalog entries…). A strict decode turned
    /// ANY such quirk into a dead placeholder addon — instead, salvage every
    /// field we can and fall back sensibly, so any addon that serves valid
    /// streams works regardless of manifest cosmetics.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        let rawName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        id = rawID ?? rawName ?? "addon"
        name = rawName ?? rawID ?? "Add-on"
        // NB: no non-nil fallback here — version's nil-ness participates in
        // isPlaceholder, and persisted placeholders must round-trip as such.
        var decodedVersion: String? = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        if decodedVersion == nil,
           let numeric = (try? c.decodeIfPresent(Double.self, forKey: .version)) ?? nil {
            decodedVersion = String(numeric)
        }
        version = decodedVersion
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        logo = (try? c.decodeIfPresent(String.self, forKey: .logo)) ?? nil
        types = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? nil
        idPrefixes = (try? c.decodeIfPresent([String].self, forKey: .idPrefixes)) ?? nil
        // Element-wise, as the comment above promises: `try?` around the whole
        // array nil'd every catalog/resource when ONE entry was malformed —
        // a stream addon whose manifest carried one odd resource object then
        // silently contributed nothing to Sources.
        catalogs = c.contains(.catalogs) ? c.lossyArrayHelper(ManifestCatalog.self, forKey: .catalogs) : nil
        resources = c.contains(.resources) ? c.lossyArrayHelper(ManifestResource.self, forKey: .resources) : nil
        behaviorHints = (try? c.decodeIfPresent(BehaviorHints.self, forKey: .behaviorHints)) ?? nil
    }

    init(id: String, name: String, version: String?, description: String?,
         logo: String?, types: [String]?, idPrefixes: [String]?,
         catalogs: [ManifestCatalog]?, resources: [ManifestResource]?,
         behaviorHints: BehaviorHints? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.logo = logo
        self.types = types
        self.idPrefixes = idPrefixes
        self.catalogs = catalogs
        self.resources = resources
        self.behaviorHints = behaviorHints
    }

    private func provides(_ resource: String) -> Bool {
        resources?.contains { $0.name == resource } ?? false
    }

    var providesStreams: Bool { provides("stream") }
    var providesMeta: Bool { provides("meta") }
    var providesCatalogs: Bool { !(catalogs ?? []).isEmpty }
    var providesSubtitles: Bool { provides("subtitles") }

    /// True while this addon exists only as a URL we couldn't fetch a manifest
    /// for yet. It contributes nothing (no catalogs/streams) but is retained so
    /// a sync push never silently drops — and thereby deletes — it.
    var isPlaceholder: Bool { resources == nil && catalogs == nil && version == nil }

    /// A minimal stand-in for an addon whose manifest failed to load. Names it
    /// after the host so the list stays recognisable; self-heals on the next
    /// successful manifest refresh.
    static func placeholder(manifestURL: String) -> AddonManifest {
        let host = URL(string: manifestURL)?.host ?? manifestURL
        return AddonManifest(id: manifestURL, name: host, version: nil,
                             description: nil, logo: nil, types: nil,
                             idPrefixes: nil, catalogs: nil, resources: nil)
    }
}

/// Manifest `resources` entries are either plain strings ("stream") or
/// objects ({"name": "stream", "types": [...], "idPrefixes": [...]}).
enum ManifestResource: Codable, Hashable {
    case simple(String)
    case detailed(name: String, types: [String]?, idPrefixes: [String]?)

    var name: String {
        switch self {
        case .simple(let name): return name
        case .detailed(let name, _, _): return name
        }
    }

    private struct Detailed: Codable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .simple(string)
        } else {
            let obj = try container.decode(Detailed.self)
            self = .detailed(name: obj.name, types: obj.types, idPrefixes: obj.idPrefixes)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .simple(let name):
            try container.encode(name)
        case .detailed(let name, let types, let idPrefixes):
            try container.encode(Detailed(name: name, types: types, idPrefixes: idPrefixes))
        }
    }
}

struct ManifestCatalog: Codable, Identifiable, Hashable {
    let type: String
    let id: String
    let name: String?
    let extra: [CatalogExtra]?
    let extraRequired: [String]?
    let extraSupported: [String]?

    /// Catalogs that require an extra argument (search, genre...) cannot be
    /// shown as plain home rows.
    var requiresExtra: Bool {
        if let extraRequired, !extraRequired.isEmpty { return true }
        return extra?.contains { $0.isRequired == true } ?? false
    }

    var displayName: String {
        let base = name ?? id.capitalized
        let typeLabel: String
        switch type {
        case "movie": typeLabel = "Movies"
        case "series": typeLabel = "Series"
        case "tv": typeLabel = "TV"
        default: typeLabel = type.capitalized
        }
        if base.lowercased().contains(typeLabel.lowercased()) { return base }
        return "\(base) \(typeLabel)"
    }
}

struct CatalogExtra: Codable, Hashable {
    let name: String?
    let isRequired: Bool?
    /// Allowed values for this extra (e.g. the genre list when `name == "genre"`).
    let options: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case isRequired
        case options
    }
}

struct InstalledAddon: Codable, Identifiable, Hashable {
    let manifestURL: String
    let manifest: AddonManifest
    /// Disabled addons stay installed but contribute no catalogs/streams — the
    /// APK's per-addon on/off toggle.
    var enabled: Bool = true
    /// The name it was given (here or on Nuvio's website — synced as the
    /// account row's `name`); nil: the manifest's own.
    var customName: String?

    var id: String { manifestURL }
    /// What the add-on is called everywhere in Cue.
    var displayName: String { customName ?? manifest.name }

    /// Its settings page, for add-ons that have one: the manifest URL with
    /// `manifest.json` replaced by `configure` (the Stremio convention), its
    /// query kept.
    var configureURL: String? {
        guard manifest.isConfigurable else { return nil }
        let (base, query) = Self.split(manifestURL: manifestURL)
        return base + "/configure" + query
    }

    private enum CodingKeys: String, CodingKey { case manifestURL, manifest, enabled, customName }

    init(manifestURL: String, manifest: AddonManifest, enabled: Bool = true, customName: String? = nil) {
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.enabled = enabled
        self.customName = customName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifestURL = try c.decode(String.self, forKey: .manifestURL)
        manifest = try c.decode(AddonManifest.self, forKey: .manifest)
        // Back-compat: addons saved before the toggle existed default to on.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
    }

    /// THE single source of truth for splitting a manifest URL into the base
    /// path every resource request hangs off, and the query/fragment that has
    /// to be carried along with it.
    ///
    /// Two derivations of this used to exist — `baseURL` here (which dropped
    /// the query) and an inline one in `AddonManager.applyRemote` (which kept
    /// it) — and for a configured addon whose manifest carries a token
    /// (`…/manifest.json?token=…`) they disagreed. Account sync then never
    /// recognised that addon as already installed: every pull re-fetched and
    /// re-appended it (shuffling it to the end of the priority order), a
    /// reconciling pull removed and re-added it, and an enable/disable made on
    /// another device never landed on it.
    static func split(manifestURL raw: String) -> (base: String, query: String) {
        var base = raw
        var query = ""
        // Query/fragment comes off FIRST. Without this the suffix test below
        // failed, `base` came back EQUAL to the manifest URL, and every
        // resource request was built as "…/manifest.json?token=…/catalog/…".
        if let mark = base.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            query = String(base[mark...])
            base = String(base[base.startIndex..<mark])
        }
        if base.hasSuffix("/manifest.json") {
            base = String(base.dropLast("/manifest.json".count))
        }
        return (base, query)
    }

    /// The base path of a manifest URL, without its query. Callers that only
    /// have the raw string (account sync, the Discover list) use this so they
    /// match `InstalledAddon.baseURL` exactly.
    static func baseURL(forManifestURL raw: String) -> String {
        split(manifestURL: raw).base
    }

    var baseURL: String { Self.split(manifestURL: manifestURL).base }

    /// Builds a resource URL for this addon: base path + `path` + the manifest
    /// URL's own query re-appended AFTER the `.json` suffix.
    ///
    /// `baseURL` alone is not enough for a configured addon: the token lives in
    /// the manifest URL's query, and plain string concatenation dropped it, so
    /// every catalog/meta/stream/subtitle request went out unauthenticated and
    /// silently came back with nothing. For the overwhelmingly common case of a
    /// manifest URL with no query this returns exactly what concatenation did.
    /// `path` is the full resource path including its leading `/` and `.json`.
    func resourceURL(_ path: String) -> String {
        let parts = Self.split(manifestURL: manifestURL)
        return parts.base + path + parts.query
    }

    /// Whether this addon claims to resolve the given content id. Prefixes can
    /// be declared at the manifest top level OR inside a detailed resource
    /// entry ({"name":"stream","idPrefixes":[…]}) — union both; an addon that
    /// declares neither is assumed to handle everything.
    func handles(id contentID: String) -> Bool {
        var prefixes = manifest.idPrefixes ?? []
        for resource in manifest.resources ?? [] {
            if case .detailed(_, _, let resourcePrefixes) = resource {
                prefixes.append(contentsOf: resourcePrefixes ?? [])
            }
        }
        guard !prefixes.isEmpty else { return true }
        return prefixes.contains { contentID.hasPrefix($0) }
    }
}

// MARK: - Meta

struct MetaItem: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let runtime: String?
    let genres: [String]?
    let cast: [String]?
    let videos: [MetaVideo]?

    private enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description
        case releaseInfo, imdbRating, runtime, genres, cast, videos, year
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decode(String.self, forKey: .type)) ?? "movie"
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        poster = try? c.decode(String.self, forKey: .poster)
        background = try? c.decode(String.self, forKey: .background)
        logo = try? c.decode(String.self, forKey: .logo)
        description = try? c.decode(String.self, forKey: .description)
        if let info = try? c.decode(String.self, forKey: .releaseInfo) {
            releaseInfo = info
        } else if let year = try? c.decode(Int.self, forKey: .year) {
            releaseInfo = String(year)
        } else if let year = try? c.decode(String.self, forKey: .year) {
            releaseInfo = year
        } else {
            releaseInfo = nil
        }
        if let rating = try? c.decode(String.self, forKey: .imdbRating) {
            imdbRating = rating
        } else if let rating = try? c.decode(Double.self, forKey: .imdbRating) {
            imdbRating = String(format: "%.1f", rating)
        } else {
            imdbRating = nil
        }
        runtime = try? c.decode(String.self, forKey: .runtime)
        genres = try? c.decode([String].self, forKey: .genres)
        cast = try? c.decode([String].self, forKey: .cast)
        // Element-wise: one episode with a numeric/missing id used to nil the
        // WHOLE list, so the Detail page showed no episodes for that show.
        videos = c.lossyArrayHelper(MetaVideo.self, forKey: .videos)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try c.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(genres, forKey: .genres)
        try c.encodeIfPresent(cast, forKey: .cast)
        try c.encodeIfPresent(videos, forKey: .videos)
    }

    init(
        id: String, type: String, name: String,
        poster: String? = nil, background: String? = nil, logo: String? = nil,
        description: String? = nil, releaseInfo: String? = nil, imdbRating: String? = nil,
        runtime: String? = nil, genres: [String]? = nil, cast: [String]? = nil,
        videos: [MetaVideo]? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.runtime = runtime
        self.genres = genres
        self.cast = cast
        self.videos = videos
    }

    var year: String? {
        guard let releaseInfo, !releaseInfo.isEmpty else { return nil }
        return String(releaseInfo.prefix(4))
    }

    var isSeries: Bool { type == "series" || type == "tv" }

    /// Capitalized content type for meta lines ("Movie" / "Series"), matching the APK.
    var typeLabel: String {
        switch type {
        case "series", "tv": return "Series"
        case "movie": return "Movie"
        default: return type.capitalized
        }
    }

    /// Runtime in the APK's "1h 49m" format (Cinemeta sends "109 min").
    var runtimeFormatted: String? {
        guard let runtime else { return nil }
        let trimmed = runtime.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("h") { return trimmed }   // already "1h 49m"-ish
        let digits = trimmed.prefix { $0.isNumber }
        guard let total = Int(digits), total > 0 else { return trimmed }
        if total >= 60 {
            let h = total / 60, m = total % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(total)m"
    }

    var seasons: [Int] {
        let numbers = Set((videos ?? []).compactMap { $0.season }.filter { $0 >= 0 })
        return numbers.sorted()
    }

    var regularSeasons: [Int] {
        seasons.filter { $0 > 0 }
    }

    var playbackSeasons: [Int] {
        regularSeasons.isEmpty ? seasons : regularSeasons
    }

    func episodes(season: Int) -> [MetaVideo] {
        (videos ?? [])
            .filter { $0.season == season }
            .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
            .deduplicatedByID()
    }

    func episodesIncludingLinkedSpecials(season: Int) -> [MetaVideo] {
        episodes(season: season)
    }
}

extension Array where Element == MetaItem {
    /// Keep only the first occurrence of each `id`. Addons — especially
    /// aggregators like AIO Metadata — routinely return the same title more
    /// than once in a single catalog. `MetaItem` is `Identifiable` by `id`, so
    /// duplicates put repeated identifiers into a `ForEach`, which is undefined
    /// in SwiftUI and crashes the tvOS focus engine. Search, Discover and the
    /// paginated "See All" already guard this way; catalogs feeding Home did
    /// not, which is why an AIO catalog could crash the app right after login.
    func deduplicatedByID() -> [MetaItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension Array where Element == MetaVideo {
    /// Same rationale as `MetaItem.deduplicatedByID` — some meta addons emit
    /// duplicate `video.id`s in an episode list, which would crash the Detail
    /// page's episode `ForEach` on tvOS.
    func deduplicatedByID() -> [MetaVideo] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

/// Statically cached parsers for the release/air-date hot paths. `hasAired`,
/// `airedDate` and `isUnreleased` used to construct 1–3 formatters PER CALL,
/// and their callers run per episode across whole series (the Next Up refresh
/// walks every episode of up to 40 shows; the Detail page re-derives its play
/// target on focus moves) — on an A8 the ICU formatter construction dwarfs the
/// parse itself. Both formatter classes are documented thread-safe.
enum ReleaseDateParser {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Bare "yyyy-MM-dd", pinned to POSIX/GMT (release-date comparisons).
    static let ymdGMT: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// Full ISO 8601 (with or without fractional seconds), else bare date.
    static func parse(_ released: String) -> Date? {
        if let d = isoFull(released) { return d }
        return ymdGMT.date(from: String(released.prefix(10)))
    }

    /// Full ISO 8601 only (with or without fractional seconds) — each string
    /// parsed ONCE, then remembered: ISO parsing is slow (ICU), and the
    /// episode list's dates were parsed again on every redraw (the Details
    /// buttons' Play target walked every episode on every focus move).
    static func isoFull(_ released: String) -> Date? {
        isoLock.lock()
        if let hit = isoCache[released] { isoLock.unlock(); return hit }
        isoLock.unlock()
        let date = isoFractional.date(from: released) ?? iso.date(from: released)
        isoLock.lock()
        if isoCache.count > 20_000 { isoCache.removeAll() }
        isoCache[released] = .some(date)
        isoLock.unlock()
        return date
    }
    private static let isoLock = NSLock()
    nonisolated(unsafe) private static var isoCache: [String: Date?] = [:]
}

struct MetaVideo: Codable, Identifiable, Hashable {
    let id: String
    let title: String?
    let season: Int?
    let episode: Int?
    let thumbnail: String?
    let overview: String?
    let released: String?
    let originalSeason: Int?
    let originalEpisode: Int?

    private enum CodingKeys: String, CodingKey {
        case id, title, name, season, episode, number, thumbnail, overview, released
        case originalSeason, originalEpisode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title))
            ?? (try? c.decode(String.self, forKey: .name))
        season = try? c.decode(Int.self, forKey: .season)
        episode = (try? c.decode(Int.self, forKey: .episode))
            ?? (try? c.decode(Int.self, forKey: .number))
        thumbnail = try? c.decode(String.self, forKey: .thumbnail)
        overview = try? c.decode(String.self, forKey: .overview)
        released = try? c.decode(String.self, forKey: .released)
        originalSeason = try? c.decode(Int.self, forKey: .originalSeason)
        originalEpisode = try? c.decode(Int.self, forKey: .originalEpisode)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(released, forKey: .released)
        try c.encodeIfPresent(originalSeason, forKey: .originalSeason)
        try c.encodeIfPresent(originalEpisode, forKey: .originalEpisode)
    }

    init(
        id: String, title: String?, season: Int?, episode: Int?,
        thumbnail: String? = nil, overview: String? = nil, released: String? = nil,
        originalSeason: Int? = nil, originalEpisode: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.season = season
        self.episode = episode
        self.thumbnail = thumbnail
        self.overview = overview
        self.released = released
        self.originalSeason = originalSeason
        self.originalEpisode = originalEpisode
    }

    var hasAired: Bool {
        guard let released else { return true }
        if let date = ReleaseDateParser.isoFull(released) { return date <= Date() }
        return true
    }

    /// Next Up may point at it: it has aired, or airs within
    /// `upcomingWindow` — a weekly show stays in Continue Watching between
    /// episodes ("Airs Tuesday"); one on a long break (or with no date) drops
    /// out, and comes back once its next episode is out.
    var isNextUpCandidate: Bool {
        if hasAired { return true }
        guard let aired = airedDate else { return false }
        return aired.timeIntervalSinceNow <= Self.upcomingWindow
    }

    static let upcomingWindow: TimeInterval = 14 * 24 * 60 * 60

    var seasonEpisodeCode: String {
        guard let season, let episode else { return "" }
        return "S\(season):E\(episode)"
    }

    var airedDate: Date? {
        guard let released, !released.isEmpty else { return nil }
        return ReleaseDateParser.parse(released)
    }

    /// "Airs in 3 days" / "Airs tomorrow" for an episode that has NOT aired
    /// yet, or nil once it has. The addon's air date is the only schedule the
    /// app has, so this is what an upcoming episode can honestly say.
    var airCountdownText: String? {
        guard !hasAired else { return nil }
        return Self.airCountdownText(until: airedDate)
    }

    /// The countdown's wording — ONE place, so the episode row and Continue
    /// Watching's Next Up card say it the same way. Nil date: "Not aired yet".
    static func airCountdownText(until date: Date?) -> String {
        guard let date else { return "Not aired yet" }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days <= 0 { return "Airs today" }
        if days == 1 { return "Airs tomorrow" }
        return "Airs in \(days) days"
    }
}

// MARK: - Streams

/// A compact fingerprint of a played stream's format, remembered with watch
/// progress so a resume can re-scrape a FRESH link (debrid/Comet links expire)
/// and pick one matching what was originally watched — same resolution, Dolby
/// Vision, HDR, Atmos, and ideally the same add-on.
struct StreamSignature: Codable, Hashable {
    var resolution: String?      // "2160p" / "1080p" / …
    var dolbyVision: Bool = false
    var hdr: Bool = false
    var atmos: Bool = false
    var addonName: String?
}

struct Stream: Codable, Hashable {
    let name: String?
    let title: String?
    let description: String?
    let url: String?
    let infoHash: String?
    let fileIdx: Int?
    /// Tracker/DHT sources for building a magnet URI (Stremio torrent streams).
    let sources: [String]?
    let behaviorHints: StreamBehaviorHints?
    private enum CodingKeys: String, CodingKey {
        case name, title, description, url, infoHash, fileIdx, sources, behaviorHints
    }

    /// Tolerant decode: addons in the wild bend the spec (numbers where
    /// strings belong, string fileIdx, malformed behaviorHints…). Any field
    /// that doesn't parse becomes nil instead of throwing, so one odd field
    /// can't invalidate the stream — and with the lossy array decode in
    /// StremioAPI, one odd stream can't blank the whole addon.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var decodedName: String? = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        if decodedName == nil, let numeric = (try? c.decodeIfPresent(Int.self, forKey: .name)) ?? nil {
            decodedName = String(numeric)
        }
        name = decodedName
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        infoHash = (try? c.decodeIfPresent(String.self, forKey: .infoHash)) ?? nil
        var decodedFileIdx: Int? = (try? c.decodeIfPresent(Int.self, forKey: .fileIdx)) ?? nil
        if decodedFileIdx == nil, let string = (try? c.decodeIfPresent(String.self, forKey: .fileIdx)) ?? nil {
            decodedFileIdx = Int(string)
        }
        fileIdx = decodedFileIdx
        sources = (try? c.decodeIfPresent([String].self, forKey: .sources)) ?? nil
        behaviorHints = (try? c.decodeIfPresent(StreamBehaviorHints.self, forKey: .behaviorHints)) ?? nil
    }

    init(
        name: String?, title: String?, description: String?, url: String?,
        infoHash: String?, fileIdx: Int? = nil, sources: [String]? = nil,
        behaviorHints: StreamBehaviorHints?
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.url = url
        self.infoHash = infoHash
        self.fileIdx = fileIdx
        self.sources = sources
        self.behaviorHints = behaviorHints
    }

    var isPlayable: Bool {
        guard let url, let parsed = URL(string: url) else { return false }
        return parsed.scheme == "http" || parsed.scheme == "https"
    }

    var isTorrent: Bool { infoHash != nil && url == nil }

    /// Debrid-cached marker, e.g. "[RD+]", "[TB+]", "PM+" — the convention
    /// Torrentio/Comet/MediaFusion use for torrents the provider already has
    /// (instant play, no download wait).
    private static let cachedMarkerRegex = try? NSRegularExpression(
        pattern: #"\b(rd|ad|pm|tb|dl|oc|pk|ed)\+"#, options: [.caseInsensitive]
    )

    private static let uncachedRegex = try? NSRegularExpression(
        pattern: #"\b(?:rd|ad|pm|tb|dl|oc|pk|torbox|debrid)\b[\s\-\]]*download|download\]|uncached|not cached"#,
        options: [.caseInsensitive]
    )
    private func isUncachedMarked(_ lower: String) -> Bool {
        if lower.contains("uncached") { return true }
        let raw = "\(name ?? "") \(title ?? "") \(description ?? "")"
        if raw.contains("⏳") || raw.contains("⌛") || raw.contains("⏬") { return true }
        guard let regex = Self.uncachedRegex else { return false }
        return regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
    }

    /// What the add-on's own text says about being cached, nil if it says nothing.
    func statedCached(in raw: String) -> Bool? {
        let lower = raw.lowercased()
        if isUncachedMarked(lower) { return false }
        // Positive cached markers used across the common addons.
        if raw.contains("⚡") || raw.contains("✅") { return true }
        if lower.contains("cached") || lower.contains("instant") { return true }
        if let regex = Self.cachedMarkerRegex,   // "[RD+]" / "[PM+]" style tags
           regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil { return true }
        return nil
    }

    private var searchHaystack: String { "\(name ?? "") \(title ?? "") \(description ?? "")".lowercased() }

    /// Dolby Vision.
    var isDolbyVision: Bool {
        let h = searchHaystack
        return h.contains("dolby vision") || h.contains("dolby.vision") || h.contains("dovi")
            || h.range(of: #"\bdv\b"#, options: .regularExpression) != nil
    }
    /// Any HDR flavor (including Dolby Vision).
    var isHDR: Bool { isDolbyVision || searchHaystack.contains("hdr") || searchHaystack.contains("hlg") }
    /// Dolby Atmos object audio (best-effort from the release name).
    var hasAtmos: Bool { searchHaystack.contains("atmos") }

    /// Fingerprint used to re-find a comparable link on resume.
    func signature(addonName: String?) -> StreamSignature {
        StreamSignature(
            resolution: resolutionLabel,
            dolbyVision: isDolbyVision,
            hdr: isHDR,
            atmos: hasAtmos,
            addonName: addonName
        )
    }

    /// Addon-provided short label, e.g. "Torrentio\n4K" — its own line
    /// breaks kept (add-ons lay their labels out in lines).
    var displayName: String {
        (name ?? "Stream").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Longer description lines with file / size details, line breaks kept.
    var displayDetail: String {
        (title ?? description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var qualityTag: String? {
        let haystack = "\(name ?? "") \(title ?? "") \(description ?? "")".lowercased()
        for tag in ["2160p", "4k", "1080p", "720p", "480p"] where haystack.contains(tag) {
            return tag == "4k" ? "4K" : tag
        }
        return nil
    }

    /// Resolution normalized to the "2160p / 1080p / 720p" form.
    var resolutionLabel: String? {
        guard let tag = qualityTag else { return nil }
        return tag == "4K" ? "2160p" : tag
    }

    /// Compiled once — `String.range(of:.regularExpression)` recompiles the
    /// pattern on every call, which was a real per-row cost on long source
    /// lists.
    private static let sizeRegex = try? NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(GB|GiB|MB|MiB)"#, options: [.caseInsensitive]
    )

    /// File size, e.g. "55.3 GB". Prefers the addon's exact byte count
    /// (behaviorHints.videoSize — Torrentio and friends set it), otherwise
    /// parses the "💾 55.3 GB"-style text most stream addons embed.
    /// NOTE: string/regex work — read it via StreamEntry's precomputed copy in
    /// row bodies, never directly per render.
    var fileSizeLabel: String? {
        if let bytes = behaviorHints?.videoSize, bytes > 0 {
            // Decimal, as the add-ons and Apple count.
            let gb = Double(bytes) / 1_000_000_000
            if gb >= 1 {
                return String(format: gb >= 100 ? "%.0f GB" : "%.2f GB", gb)
            }
            let mb = Double(bytes) / 1_000_000
            return String(format: "%.0f MB", mb)
        }
        let haystack = "\(name ?? "") \(title ?? "") \(description ?? "")"
        guard let regex = Self.sizeRegex,
              let match = regex.firstMatch(
                in: haystack, options: [],
                range: NSRange(haystack.startIndex..., in: haystack)
              ),
              let range = Range(match.range, in: haystack) else { return nil }
        let matched = haystack[range]
        let unit = matched.lowercased().contains("m") ? "MB" : "GB"
        let number = matched.trimmingCharacters(in: CharacterSet(charactersIn: " GgBbIiMm"))
        return "\(number) \(unit)"
    }

    /// Numeric file size in bytes for sorting/ranking sources (the high-GB vs
    /// low-GB split). Prefers the exact `behaviorHints.videoSize`, else parses
    /// the embedded "💾 55.3 GB" text. nil when no size is discoverable — such
    /// sources sort as smallest so they fill data-saver slots, not top ones.
    var sizeBytes: Int64? {
        if let bytes = behaviorHints?.videoSize, bytes > 0 { return bytes }
        let haystack = "\(name ?? "") \(title ?? "") \(description ?? "")"
        guard let regex = Self.sizeRegex,
              let match = regex.firstMatch(
                in: haystack, options: [],
                range: NSRange(haystack.startIndex..., in: haystack)
              ),
              let numberRange = Range(match.range(at: 1), in: haystack),
              let unitRange = Range(match.range(at: 2), in: haystack),
              let value = Double(haystack[numberRange]) else { return nil }
        let multiplier: Double = haystack[unitRange].lowercased().hasPrefix("m")
            ? 1_000_000 : 1_000_000_000
        // `Int64(Double)` TRAPS past 2^63. The digits come from addon text
        // (`\d+` is unbounded), so a long numeric id glued to "GB" in a
        // release title was a remote crash while the Sources list was built.
        let product = value * multiplier
        guard product.isFinite, product < 9.2e18 else { return nil }
        return Int64(product)
    }
}

struct StreamBehaviorHints: Codable, Hashable {
    let bingeGroup: String?
    let notWebReady: Bool?
    /// Exact video size in bytes (Stremio SDK field, set by Torrentio etc.).
    let videoSize: Int64?
    let filename: String?
    /// Headers the addon wants sent WITH the media request (Stremio's
    /// `behaviorHints.proxyHeaders`). Scraper addons hand back a CDN link that
    /// only answers with the right `Referer`/`User-Agent` — without them the
    /// host returns 403 and the source looks broken. Only `request` is
    /// actionable for us; `response` is a browser-player concern.
    let proxyHeaders: StreamProxyHeaders?

    private enum CodingKeys: String, CodingKey {
        case bingeGroup, notWebReady, videoSize, filename, proxyHeaders
    }

    /// Tolerant decode, same policy as `Stream`: one malformed hint (a string
    /// `videoSize`, a proxyHeaders map with non-string values) must not blank
    /// the whole hints object and take the good fields down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bingeGroup = (try? c.decodeIfPresent(String.self, forKey: .bingeGroup)) ?? nil
        notWebReady = (try? c.decodeIfPresent(Bool.self, forKey: .notWebReady)) ?? nil
        var decodedSize: Int64? = (try? c.decodeIfPresent(Int64.self, forKey: .videoSize)) ?? nil
        if decodedSize == nil, let string = (try? c.decodeIfPresent(String.self, forKey: .videoSize)) ?? nil {
            decodedSize = Int64(string)
        }
        videoSize = decodedSize
        filename = (try? c.decodeIfPresent(String.self, forKey: .filename)) ?? nil
        proxyHeaders = (try? c.decodeIfPresent(StreamProxyHeaders.self, forKey: .proxyHeaders)) ?? nil
    }

    /// Memberwise: for streams built in-app (plugin scrapers) rather than
    /// decoded from an addon response.
    init(bingeGroup: String? = nil, notWebReady: Bool? = nil, videoSize: Int64? = nil,
         filename: String? = nil, proxyHeaders: StreamProxyHeaders? = nil) {
        self.bingeGroup = bingeGroup
        self.notWebReady = notWebReady
        self.videoSize = videoSize
        self.filename = filename
        self.proxyHeaders = proxyHeaders
    }
}

struct StreamProxyHeaders: Codable, Hashable {
    /// Header name → value, applied to the outgoing media request.
    let request: [String: String]?

    private enum CodingKeys: String, CodingKey { case request }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = (try? c.decodeIfPresent([String: String].self, forKey: .request)) ?? nil
    }

    init(request: [String: String]?) { self.request = request }

    /// Non-empty header map, or nil — the form every caller actually wants.
    var requestHeaders: [String: String]? {
        guard let request, !request.isEmpty else { return nil }
        return request
    }
}

/// A stream tagged with the addon it came from, used across the stream
/// selection UI and in-player source switching.
struct StreamEntry: Identifiable, Hashable {
    let id = UUID()
    let addonName: String
    let stream: Stream

    /// The add-on this link came from, with any resolver prefix removed.
    ///
    /// A debrid or P2P resolve re-labels the entry it hands to the player
    /// ("RD · Torrentio", "P2P · Torrentio") so the row says who resolved it,
    /// while every other copy of that link in the pool keeps the plain name.
    /// Comparing the labels directly therefore never matched for anyone using
    /// debrid — which is what sent a failover to a DIFFERENT add-on instead of
    /// the next link from the one the viewer was on. Compare THIS.
    var sourceAddonName: String {
        guard let separator = addonName.range(of: " · ", options: .backwards) else { return addonName }
        return String(addonName[separator.upperBound...])
    }

    /// Identity of a link across sweeps. NOT the URL: a debrid link is freshly
    /// signed on every resolve, so keying on it would never match twice. An infoHash is
    /// the same torrent forever; a filename is the same file; the display
    /// strings are the last resort.
    var rejectionKey: String {
        if let hash = stream.infoHash?.lowercased(), !hash.isEmpty {
            return "hash:\(hash)#\(stream.fileIdx ?? -1)"
        }
        if let file = stream.behaviorHints?.filename, !file.isEmpty {
            return "file:\(addonName)|\(file)"
        }
        return "name:\(addonName)|\(displayName)|\(displayDetail)"
    }
    /// Display strings PRECOMPUTED here, once per entry: computing them in
    /// row bodies (regex + string builds, × every visible row × every focus
    /// move) was the main Sources-page scroll cost.
    let displayName: String
    let displayDetail: String
    let resolutionLabel: String?
    let fileSizeLabel: String?
    /// Numeric size for ranking; nil = unknown.
    let sizeBytes: Int64?
    /// What the link's text says, for the styled source cards.
    let facts: StreamFacts

    init(addonName: String, stream: Stream) {
        self.addonName = addonName
        self.stream = stream
        displayName = stream.displayName
        displayDetail = stream.displayDetail
        resolutionLabel = stream.resolutionLabel
        fileSizeLabel = stream.fileSizeLabel
        sizeBytes = stream.sizeBytes
        facts = StreamFacts(stream)
    }

    static func == (lhs: StreamEntry, rhs: StreamEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The key facts of a link, read by known words, not positions: add-ons' text
/// differs per config. AIOStreams' formatters like Unicode small caps, so the
/// text is made plain first. The file name fills in what the text leaves out;
/// what neither says stays nil.
struct StreamFacts: Hashable {
    let resolution: String?
    /// "Bluray Remux"
    let quality: String?
    let size: String?
    let bitrate: String?
    /// "German, English", "German, English, French +3"
    let language: String?
    /// As the add-on says, nil if it doesn't.
    let cached: Bool?
    /// "DV · HDR10+ · HEVC"
    let video: String?
    /// "TrueHD Atmos · 7.1"
    let audio: String?
    /// The release group or provider, and any editions.
    let origin: [String]
    /// With AIOStreams, the add-on behind the link: the template's last line starts with it.
    let gatheredFrom: String?

    init(_ stream: Stream) {
        let text = Self.plain("\(stream.name ?? "") \(stream.title ?? "") \(stream.description ?? "")")
        let file = Self.plain(stream.behaviorHints?.filename ?? "")
        let all = text + " " + file
        resolution = Self.first(Self.resolutions, in: all)
        quality = Self.first(Self.qualities, in: all)
        size = Self.size(of: stream, in: text)
        bitrate = Self.bitrate(in: text)
        language = Self.language(in: text)
        cached = stream.statedCached(in: text)
        video = Self.video(in: all)
        audio = Self.audio(in: all)
        let editions = Self.editions.filter { Self.matches($0.0, all) }.map(\.1)
        origin = [Self.group(of: stream, file: file)].compactMap { $0 } + editions
        let lastLine = (stream.description ?? "").components(separatedBy: .newlines).last { !$0.isEmpty }
        let lastParts = (lastLine ?? "").components(separatedBy: "·")
        gatheredFrom = lastLine == nil ? nil : lastParts[0].trimmingCharacters(in: .whitespaces)
    }

    private static let smallCaps: [Character: Character] = [
        "ᴀ": "A", "ʙ": "B", "ᴄ": "C", "ᴅ": "D", "ᴇ": "E", "ꜰ": "F", "ғ": "F", "ɢ": "G", "ʜ": "H",
        "ɪ": "I", "ᴊ": "J", "ᴋ": "K", "ʟ": "L", "ᴍ": "M", "ɴ": "N", "ᴏ": "O", "ᴘ": "P", "ǫ": "Q",
        "ʀ": "R", "ꜱ": "S", "ᴛ": "T", "ᴜ": "U", "ᴠ": "V", "ᴡ": "W", "ʏ": "Y", "ᴢ": "Z"
    ]

    /// The compatibility mapping takes care of the mathematical alphabets.
    private static func plain(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.map { smallCaps[$0] ?? ($0 == "_" ? " " : $0) })
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Best first, each a whole word; a digit may follow ("DDP5.1").
    private static func table(_ words: [(String, String)]) -> [(NSRegularExpression?, String)] {
        words.map { (regex("(?<![a-z0-9])(?:\($0.0))(?![a-z])"), $0.1) }
    }

    private static let resolutions = table([
        ("2160p|4k|uhd", "4K"), ("1440p", "1440p"), ("1080p|fhd", "1080p"),
        ("720p", "720p"), ("576p", "576p"), ("480p", "480p")
    ])
    private static let qualities = table([
        ("remux", "Bluray Remux"), ("blu-?ray|bdrip|brrip", "Bluray"), ("web-?dl", "Web-dl"), ("web-?rip", "Webrip"),
        ("web", "Web"), ("hdtv", "HDTV"), ("dvd(?:rip)?", "DVD"), ("hd-?cam|cam(?:rip)?|telesync|hd-?ts", "Cam")
    ])
    private static let pictures = table([
        ("dv|dovi|dolby[ .]?vision", "DV"), ("hdr10\\+|hdr10plus", "HDR10+"), ("hdr(?:10)?", "HDR")
    ])
    private static let codecs = table([
        ("hevc|x\\.?265|h\\.?265", "HEVC"), ("av1", "AV1"), ("vp9", "VP9"), ("avc|x\\.?264|h\\.?264", "AVC")
    ])
    private static let languages = table([
        ("english", "English"), ("german", "German"), ("french", "French"), ("spanish", "Spanish"), ("latino", "Latino"),
        ("italian", "Italian"), ("portuguese", "Portuguese"), ("dutch", "Dutch"), ("russian", "Russian"),
        ("ukrainian", "Ukrainian"), ("polish", "Polish"), ("czech", "Czech"), ("turkish", "Turkish"),
        ("swedish", "Swedish"), ("norwegian", "Norwegian"), ("danish", "Danish"), ("finnish", "Finnish"),
        ("greek", "Greek"), ("hungarian", "Hungarian"), ("romanian", "Romanian"), ("arabic", "Arabic"),
        ("hindi", "Hindi"), ("tamil", "Tamil"), ("telugu", "Telugu"), ("japanese", "Japanese"), ("korean", "Korean"),
        ("chinese", "Chinese"), ("thai", "Thai"), ("vietnamese", "Vietnamese")
    ])
    private static let audios = table([
        ("truehd", "TrueHD"), ("dts[:.\\- ]?x", "DTS:X"), ("dts-?hd[ .-]?ma", "DTS-HD MA"), ("dts-?hd", "DTS-HD"),
        ("dd\\+|ddp|e-?ac-?3", "DD+"), ("dts", "DTS"), ("dd|ac-?3", "DD"), ("flac", "FLAC"), ("aac", "AAC"), ("opus", "Opus")
    ])
    private static let editions = table([
        ("extended", "Extended"), ("director'?s?[ .]?cut", "Director's Cut"), ("theatrical", "Theatrical"),
        ("unrated", "Unrated"), ("uncut", "Uncut"), ("imax", "IMAX"), ("remaster(?:ed)?", "Remastered"),
        ("criterion", "Criterion")
    ])
    private static let atmos = regex("(?<![a-z0-9])atmos(?![a-z])")
    private static let channels = regex(#"(?<![\d.])[2567]\.[01](?![\d.])"#)
    private static let sizes = regex(#"(\d+(?:\.\d+)?)\s*(TB|GB|GiB|MB|MiB)(?![a-z])"#)
    private static let bitrates = regex(#"(\d+(?:\.\d+)?)\s*Mbps"#)
    private static let groups = regex(#"-([a-z0-9]+)(?:\.[a-z0-9]{2,4})?\s*$"#)

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func first(_ table: [(NSRegularExpression?, String)], in text: String) -> String? {
        table.first { matches($0.0, text) }?.1
    }

    /// The whole match, then its groups.
    private static func parts(_ regex: NSRegularExpression?, in text: String) -> [String]? {
        guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// Whatever there is, nil if nothing.
    private static func listed(_ parts: [String?]) -> String? {
        let found = parts.compactMap { $0 }
        return found.isEmpty ? nil : found.joined(separator: " · ")
    }

    private static func video(in text: String) -> String? {
        let pictures = pictures.filter { matches($0.0, text) }.map(\.1)
        // "HDR" also matches inside "HDR10+".
        let picture = pictures.contains("HDR10+") ? pictures.filter { $0 != "HDR" } : pictures
        return listed(picture + [first(codecs, in: text)])
    }

    private static func audio(in text: String) -> String? {
        let codec = first(audios, in: text)
        let format = matches(atmos, text) ? [codec, "Atmos"].compactMap { $0 }.joined(separator: " ") : codec
        return listed([format, parts(channels, in: text)?.first])
    }

    private static func size(of stream: Stream, in text: String) -> String? {
        // The add-on's own figure; the file's bytes only where its text has none.
        if let found = parts(sizes, in: text), found.count == 3 {
            return "\(found[1]) \(found[2].prefix(1).uppercased())B"
        }
        if let bytes = stream.behaviorHints?.videoSize, bytes > 0 { return stream.fileSizeLabel }
        return nil
    }

    private static func bitrate(in text: String) -> String? {
        guard let found = parts(bitrates, in: text), found.count == 2 else { return nil }
        return "\(found[1]) Mbps"
    }

    /// In the order the text names them.
    private static func language(in text: String) -> String? {
        let found = languages.compactMap { entry -> (Int, String)? in
            entry.0?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { ($0.range.location, entry.1) }
        }.sorted { $0.0 < $1.0 }
        guard !found.isEmpty else { return nil }
        let shown = found.prefix(3).map(\.1).joined(separator: ", ")
        return found.count > 3 ? "\(shown) +\(found.count - 3)" : shown
    }

    /// The release group: the end of AIOStreams' binge group, else of a scene
    /// file name.
    private static func group(of stream: Stream, file: String) -> String? {
        let binge = stream.behaviorHints?.bingeGroup?.components(separatedBy: "|") ?? []
        if binge.count > 3, let last = binge.last, !last.isEmpty { return last }
        guard let found = parts(groups, in: file), found.count == 2, Int(found[1]) == nil else { return nil }
        return found[1]
    }
}

// MARK: - API response envelopes

struct CatalogResponse: Codable {
    let metas: [MetaItem]?

    private enum CodingKeys: String, CodingKey { case metas }

    /// Lossy array decode, same policy as `StreamsResponse`: one malformed
    /// meta (a numeric `id` from a loose aggregator) drops that entry, not the
    /// whole Home row / search result / See-All page.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metas = c.lossyArrayHelper(MetaItem.self, forKey: .metas)
    }

    init(metas: [MetaItem]?) { self.metas = metas }
}

/// Element-wise decode of an array where one bad element must not sink the
/// rest — the policy every addon-facing list in this file shares.
extension KeyedDecodingContainerProtocol {
    fileprivate func lossyArrayHelper<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        guard var array = try? nestedUnkeyedContainer(forKey: key) else { return nil }
        var collected: [T] = []
        while !array.isAtEnd {
            if let element = try? array.decode(T.self) {
                collected.append(element)
            } else {
                _ = try? array.decode(AnyIgnorable.self)
            }
        }
        return collected
    }
}

struct MetaResponse: Codable {
    let meta: MetaItem?
}

struct StreamsResponse: Codable {
    let streams: [Stream]?

    private enum CodingKeys: String, CodingKey { case streams }

    /// Lossy array decode: one malformed entry from a loose addon drops just
    /// that entry, not the addon's entire response (which previously made the
    /// whole addon vanish from Sources).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard var array = try? c.nestedUnkeyedContainer(forKey: .streams) else {
            streams = nil
            return
        }
        var collected: [Stream] = []
        while !array.isAtEnd {
            if let stream = try? array.decode(Stream.self) {
                collected.append(stream)
            } else {
                // Skip the malformed element (decode into a throwaway).
                _ = try? array.decode(AnyIgnorable.self)
            }
        }
        streams = collected
    }

    init(streams: [Stream]?) { self.streams = streams }
}

/// Decodes and discards any JSON value — used to skip malformed array
/// elements during lossy decodes.
struct AnyIgnorable: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
        if (try? c.decode(Bool.self)) != nil { return }
        if (try? c.decode(Double.self)) != nil { return }
        if (try? c.decode(String.self)) != nil { return }
        if (try? c.decode([AnyIgnorable].self)) != nil { return }
        _ = try? c.decode([String: AnyIgnorable].self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// A point in a series, ordered season-then-episode.
///
/// Comparing `(season, episode)` tuples inline works but reads badly and was
/// getting rewritten at each call site; this gives the ordering one name.
struct SeasonEpisode: Comparable, Hashable {
    let season: Int
    let episode: Int

    static func < (a: SeasonEpisode, b: SeasonEpisode) -> Bool {
        (a.season, a.episode) < (b.season, b.episode)
    }
}
