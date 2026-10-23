import SwiftUI

/// Details' last row, About: three columns of one width side by side, each
/// as long as it needs (down to the screen's bottom), read left to right —
/// what it is, what happens, the details. The genres, then the tags (TMDB's
/// keywords), as chips shaped like the ratings' — each opens its titles
/// (focus comes in on the first genre); the summary, whole; the facts, two
/// to a line — when/how long/rated → who → where from → how big — and every
/// rating, wrapping. (The network and studios are a row of their own,
/// before this one.)
struct DetailAbout: View {
    let meta: MetaItem
    let about: TMDBService.About?
    let facts: TMDBService.TitleFacts?
    let releaseDate: String?
    let contentRating: String?
    let language: String?
    let ratings: MDBListRatings?
    let settings: MDBListSettings
    /// The studios have logos (shown in their row): none here by name.
    var studiosShown = false
    /// The title's crew (a film's writers come from it).
    var crew: [TMDBService.CastMember] = []
    var onSelectGenre: (TMDBService.Genre) -> Void = { _ in }
    var onSelectKeyword: (TMDBService.Keyword) -> Void = { _ in }
    let onFocus: (Bool) -> Void
    /// Its content's height, as laid out (the rows rest it so it just fits).
    var onContentHeight: (CGFloat) -> Void = { _ in }
    /// Goes up: focus onto the first genre (else tag).
    var focusRequest = 0

    private enum Chip: Hashable { case genre(TMDBService.Genre), keyword(TMDBService.Keyword) }
    @FocusState private var focused: Chip?

    /// TMDB's genres (else the catalog's, where TMDB knows the name).
    var genres: [TMDBService.Genre] {
        if let genres = about?.genres, !genres.isEmpty { return genres }
        return (meta.genres ?? []).compactMap { TMDBService.genre(named: $0, isMovie: !meta.isSeries) }
    }
    private var keywords: [TMDBService.Keyword] { about?.keywords ?? [] }

    static let boxGap: CGFloat = 64
    static var boxWidth: CGFloat {
        ((1920 - FixedFocusMetrics.titleInset - Spotlight.screenInset - 2 * boxGap) / 3).rounded(.down)
    }
    static let columnGap: CGFloat = 24
    /// Between the title's name above and About's first line.
    static let topGap: CGFloat = 8

    private var columnWidth: CGFloat { ((Self.boxWidth - Self.columnGap) / 2).rounded(.down) }

    var body: some View {
        HStack(alignment: .top, spacing: Self.boxGap) {
            genresBox
            summaryBox
            factsBox
        }
        .padding(.top, Self.topGap)
        .background { GeometryReader { geo in
            Color.clear
                .onAppear { onContentHeight(geo.size.height) }
                .onChange(of: geo.size.height) { _, height in onContentHeight(height) }
        } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The page's end: a dark band from a little above About's name, the
        // screen's width, all the way down — a clean edge at its top.
        .background(alignment: .topLeading) { band }
        .onChange(of: focused) { _, now in onFocus(now != nil) }
        .onChange(of: focusRequest) { _, _ in
            if let first = genres.first { focused = .genre(first) }
            else if let first = keywords.first { focused = .keyword(first) }
        }
    }

    /// About's band: black at half.
    static let bandOpacity = 0.5
    /// How far above About's name the band starts (its name: above this
    /// view — see `FixedFocusRows.customRows`).
    static var bandRise: CGFloat { FixedFocusMetrics.titleHeight + 36 }

    private var band: some View {
        Color.black.opacity(Self.bandOpacity)
        // (The whole screen's width, from the screen's left edge; past the
        // screen's bottom.)
        .frame(width: 1920, height: 1400)
        .offset(x: -FixedFocusMetrics.titleInset, y: -Self.bandRise)
        .allowsHitTesting(false)
    }

    // MARK: Boxes

    /// The summary, whole, under its name (as the other columns' parts).
    /// (Also in Details' Summary panel.)
    var summaryBox: some View {
        Group {
            if let text = meta.description, !text.isEmpty {
                labelled("Summary") {
                    Text(text)
                        .font(.system(size: 24))
                        .lineSpacing(5)
                        .foregroundStyle(Color.white.opacity(FixedFocusText.caption))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: Self.boxWidth, alignment: .topLeading)
    }

    /// The facts two to a line (an empty one leaves no gap), then every
    /// rating. (Also beside the summary in Details' Summary panel.)
    var factsBox: some View {
        let all = factLines.flatMap { $0 }
        let rows = stride(from: 0, to: all.count, by: 2).map { Array(all[$0 ..< min($0 + 2, all.count)]) }
        let entries = MDBListRatingsRow.entries(ratings, settings: settings, imdbFallback: meta.imdbRating,
                                                 onDetails: true)
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: Self.columnGap) {
                    ForEach(rows[r], id: \.0) { label, value in
                        fact(label, value).frame(width: columnWidth, alignment: .leading)
                    }
                }
            }
            if !entries.isEmpty {
                labelled("Ratings") {
                    MDBListRatingsRow(entries: entries, wraps: true)
                }
            }
        }
        .frame(width: Self.boxWidth, alignment: .topLeading)
    }

    /// The genres, then the tags — chips, wrapping, each opening its titles.
    private var genresBox: some View {
        VStack(alignment: .leading, spacing: 30) {
            if !genres.isEmpty {
                labelled("Genres") {
                    InfuseWrapRow(spacing: 10, lineSpacing: 10) {
                        ForEach(genres, id: \.self) { genre in
                            Button { onSelectGenre(genre) } label: { Text(genre.name) }
                                .buttonStyle(AboutChipStyle())
                                .focused($focused, equals: .genre(genre))
                        }
                    }
                }
            }
            if !keywords.isEmpty {
                labelled("Tags") {
                    InfuseWrapRow(spacing: 10, lineSpacing: 10) {
                        ForEach(keywords, id: \.self) { keyword in
                            Button { onSelectKeyword(keyword) } label: { Text(keyword.name) }
                                .buttonStyle(AboutChipStyle())
                                .focused($focused, equals: .keyword(keyword))
                        }
                    }
                }
            }
        }
        .frame(width: Self.boxWidth, alignment: .topLeading)
        // Into About from above: on the first genre (else tag), not the chip
        // nearest to where focus came from.
        .focusSection()
        .defaultFocus($focused, genres.first.map(Chip.genre) ?? keywords.first.map(Chip.keyword),
                      priority: .userInitiated)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Self.label(label)
            Text(value)
                .font(.system(size: 24))
                .foregroundStyle(Color.white.opacity(FixedFocusText.caption))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 17, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Color.white.opacity(FixedFocusText.captionDetail))
    }

    // MARK: Facts

    /// When and how long, for whom → who made it → where from → how big.
    private var factLines: [[(String, String)]] {
        var when: [(String, String)] = []
        var who: [(String, String)] = []
        if meta.isSeries {
            if let years = airYears { when.append(("Aired", years)) }
            if let size = SeriesEpisodes.size(of: meta) {
                when.append(("Episodes", "\(size.episodes) in \(size.seasons) \(size.seasons == 1 ? "season" : "seasons")"))
            }
        } else {
            if let released = Self.shortDate(releaseDate) ?? meta.releaseInfo { when.append(("Released", released)) }
            if let minutes = facts?.runtimeMinutes, minutes > 0 { when.append(("Runtime", Self.duration(minutes))) }
        }
        if let rating = contentRating, !rating.isEmpty { when.append(("Rated", rating)) }
        // "Director: …" / "Creators: …".
        if let line = facts?.creatorLine, let colon = line.firstIndex(of: ":") {
            who.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        if !meta.isSeries {
            let writers = crew.filter { member in
                let jobs = member.character?.split(separator: "·").first ?? ""
                return jobs.contains("Writer") || jobs.contains("Screenplay")
            }.map(\.name)
            if !writers.isEmpty { who.append((writers.count == 1 ? "Writer" : "Writers", writers.prefix(2).joined(separator: ", "))) }
        }
        // Studios with no logo to show (no row of them): by name.
        if !studiosShown, let studios = about?.studios, !studios.isEmpty {
            who.append(("Studio", studios.prefix(2).joined(separator: ", ")))
        }
        var origin: [(String, String)] = []
        if let code = language?.lowercased(), let name = Locale.current.localizedString(forLanguageCode: code) {
            origin.append(("Language", name))
        }
        if let countries = about?.countries, !countries.isEmpty {
            origin.append((countries.count == 1 ? "Country" : "Countries", countries.prefix(2).joined(separator: ", ")))
        }
        if let original = about?.originalTitle, !original.isEmpty, original != meta.name {
            origin.append(("Original Title", original))
        }
        var money: [(String, String)] = []
        if let budget = about?.budget { money.append(("Budget", Self.money(budget))) }
        if let revenue = about?.revenue { money.append(("Box Office", Self.money(revenue))) }
        return [when, who, origin, money].filter { !$0.isEmpty }
    }

    /// "18 Dec 2002" — the columns are narrow.
    private static func shortDate(_ iso: String?) -> String? {
        guard let iso, let date = isoDay.date(from: String(iso.prefix(10))) else { return nil }
        return shortDay.string(from: date)
    }
    private static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let shortDay: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    /// "2016 – 2024", "2016 – Present" while it runs.
    private var airYears: String? {
        guard let first = (releaseDate ?? meta.releaseInfo).map({ String($0.prefix(4)) }) else { return nil }
        if facts?.status == "ONGOING" { return "\(first) – Present" }
        guard let last = about?.lastAirDate.map({ String($0.prefix(4)) }), last != first else { return first }
        return "\(first) – \(last)"
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        // (The facts' gap: the boxes' values line up.)
        VStack(alignment: .leading, spacing: 6) {
            Self.label(label)
            content()
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// "$185M", "$1.1B".
    static func money(_ dollars: Int) -> String {
        let value = Double(dollars)
        if value >= 1_000_000_000 { return String(format: "$%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "$%.0fM", value / 1_000_000) }
        return "$\(dollars)"
    }
}

/// A genre or tag: the rating chips' shape and height, filled instead of
/// outlined, as wide as its word. Focused: the white fill, dark text, a
/// little larger; pressed, a little less.
private struct AboutChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chip(configuration: configuration) }

    private struct Chip: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isFocused ? FlatControl.contentOnFocus : Color.white.opacity(FixedFocusText.caption))
                .lineLimit(1)
                .frame(height: 21)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isFocused ? FlatControl.focus : Color.white.opacity(0.14)))
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.04 : 1.1) : 1)
                .animation(Motion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Details' Info: the summary in full, in a glass panel over the page (it
/// floats — glass), About's facts and ratings under it. Select or Back
/// closes it.
struct DetailSummaryPanel<Summary: View, Facts: View>: View {
    let title: String
    /// The genres, under the name (a page header's subtitle).
    let genres: String
    /// About's own columns — its size, levels and widths.
    let summary: Summary
    let facts: Facts
    let onClose: () -> Void
    /// Focus comes to it when it opens (over the UIKit rows: Back must close
    /// it, not the page).
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            Button(action: onClose) {
                VStack(alignment: .leading, spacing: 28) {
                    // As a row's name (About's in the rows), the genres
                    // under it as a page header's subtitle.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.system(size: Spotlight.headerTitleSize, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(FixedFocusText.heading))
                            .fixedSize(horizontal: false, vertical: true)
                        if !genres.isEmpty {
                            Text(genres)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(Color.white.opacity(FixedFocusText.captionDetail))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: DetailAbout.boxWidth, alignment: .leading)
                    // One column, About's width: the summary, then the facts
                    // and ratings, a little further apart than the facts' lines.
                    VStack(alignment: .leading, spacing: 28) {
                        summary
                        facts
                    }
                }
                .padding(56)
                .background { Color.clear.liquidGlass(in: RoundedRectangle(cornerRadius: 44, style: .continuous)) }
            }
            .buttonStyle(SummaryPanelStyle())
            .focused($focused)
        }
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
    }
}

/// The panel draws itself: no focus chrome.
private struct SummaryPanelStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
