import Foundation

/// Read-only access to Trakt's public lists and browse endpoints — the
/// sources a collection folder can pull titles from. No account: every call
/// here is authenticated by the app's client id alone (`trakt-api-key`).
enum TraktService {
    private static let base = "https://api.trakt.tv"

    /// Public client id (header `trakt-api-key`).
    static let clientID = Secrets.traktClientID

    /// Whether Trakt list sources can resolve at all.
    static var isConfigured: Bool { !clientID.isEmpty }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    /// Returns nil for a path that can't form a URL — it used to force-unwrap.
    /// Paths are interpolated from user-supplied text (a pasted trakt.tv list
    /// URL via `parseListIDPath`, whose regex branches happily return an id
    /// containing a space or a quote), so `URL(string:)` returned nil and
    /// adding a collection source TRAPPED. Illegal characters are
    /// percent-escaped first, so a merely-unescaped path still resolves and
    /// only genuine nonsense fails — as nil, which every caller already has a
    /// graceful path for.
    private static func request(_ path: String) -> URLRequest? {
        let url = URL(string: base + path)
            // path ∪ query so the escape pass can't mangle "?…&…=" on a path
            // that carries a query string.
            ?? path.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.urlPathAllowed.union(.urlQueryAllowed)
            ).flatMap { URL(string: base + $0) }
        guard let url else {
            NSLog("[OrivioTrakt] unusable request path %@", path)
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        return request
    }

    // MARK: Public lists (collection sources)

    struct PublicListInfo: Hashable {
        let traktListId: Int64
        let title: String
        let description: String?
    }

    /// Parse a bare list id, a slug, or a full trakt.tv list URL — mirrors the
    /// Android app's tolerant input (`parseTraktListPath`).
    static func parseListIDPath(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if Int64(trimmed) != nil { return trimmed }
        for pattern in [#"[?&]id=([^&#/]+)"#, #"trakt\.tv/lists/([^/?#]+)"#, #"trakt\.tv/users/[^/]+/lists/([^/?#]+)"#] {
            if let range = trimmed.range(of: pattern, options: .regularExpression) {
                let match = String(trimmed[range])
                if let idRange = match.range(of: #"[^/=]+$"#, options: .regularExpression) {
                    return String(match[idRange])
                }
            }
        }
        let slugCharset = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return trimmed.unicodeScalars.allSatisfy(slugCharset.contains) ? trimmed : nil
    }

    /// Metadata for a public (or the signed-in user's own) Trakt list — no auth
    /// required. `input` accepts an id, slug, or full trakt.tv URL.
    static func publicListInfo(input: String) async -> PublicListInfo? {
        guard let idPath = parseListIDPath(input) else { return nil }
        struct Response: Decodable {
            struct IDs: Decodable { let trakt: Int64? }
            let name: String?; let description: String?; let ids: IDs?
        }
        guard let req = request("/lists/\(idPath)?extended=full") else { return nil }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = try? JSONDecoder().decode(Response.self, from: data),
              let traktID = body.ids?.trakt, let name = body.name else { return nil }
        return PublicListInfo(traktListId: traktID, title: name, description: body.description)
    }

    /// One raw item from a public list — enough to build a MetaItem once the
    /// caller resolves poster art (Trakt's own image extension needs VIP).
    struct PublicListItem: Hashable {
        let imdb: String?
        let tmdb: Int?
        let title: String
        let year: Int?
        let isMovie: Bool
    }

    /// Items from one of Trakt's BROWSE endpoints — `movies/trending`,
    /// `shows/popular` — with an optional filter query (`networks=Netflix`,
    /// `years=$YEAR`; `$YEAR` is the current year at request time). Trending
    /// and anticipated rows wrap the media in `{movie:…}` / `{show:…}`;
    /// popular rows ARE the media object, so both shapes are read.
    static func endpointItems(path: String, query: String?, type: String) async -> [PublicListItem] {
        struct IDs: Decodable { let imdb: String?; let tmdb: Int? }
        struct Media: Decodable { let title: String?; let year: Int?; let ids: IDs? }
        struct Row: Decodable {
            let movie: Media?; let show: Media?
            let title: String?; let year: Int?; let ids: IDs?
        }
        var full = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var params = ["limit=60"]
        if let query, !query.isEmpty {
            let year = String(Calendar.current.component(.year, from: Date()))
            params.append(query.replacingOccurrences(of: "$YEAR", with: year))
        }
        full += (full.contains("?") ? "&" : "?") + params.joined(separator: "&")
        guard let req = request(full) else { return [] }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode != 200 { NSLog("[OrivioTrakt] GET %@ → HTTP %d", full, http.statusCode) }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.compactMap { row in
            let isMovie = row.movie != nil || (row.show == nil && type == "movie")
            let media = row.movie ?? row.show
                ?? (row.title != nil ? Media(title: row.title, year: row.year, ids: row.ids) : nil)
            guard let media, let title = media.title else { return nil }
            return PublicListItem(imdb: media.ids?.imdb, tmdb: media.ids?.tmdb, title: title,
                                  year: media.year, isMovie: isMovie)
        }
    }

    /// Items in a public Trakt list. `type` is "movie" or "show".
    static func publicListItems(traktListId: Int64, type: String, sortBy: String, sortHow: String) async -> [PublicListItem] {
        struct Row: Decodable {
            struct IDs: Decodable { let imdb: String?; let tmdb: Int? }
            struct Media: Decodable { let title: String?; let year: Int?; let ids: IDs? }
            let type: String?; let movie: Media?; let show: Media?
        }
        let path = "/lists/\(traktListId)/items/\(type)"
        // No `extended=full`: Row reads only type/title/year/ids, and the
        // extended payload (overview, votes, translation metadata…) multiplied
        // the response size of a 200-item page for nothing — decoded per
        // folder open on the A8's CPU.
        guard let req = request(path + "?limit=200&sort_by=\(sortBy)&sort_how=\(sortHow)") else {
            return []
        }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode != 200 { NSLog("[OrivioTrakt] GET %@ → HTTP %d", path, http.statusCode) }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.compactMap { row in
            let isMovie = (row.type ?? type) == "movie"
            guard let media = isMovie ? row.movie : row.show, let title = media.title else { return nil }
            return PublicListItem(imdb: media.ids?.imdb, tmdb: media.ids?.tmdb, title: title,
                                  year: media.year, isMovie: isMovie)
        }
    }
}
