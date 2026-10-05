import SwiftUI

/// Details' last row, About: what the overview leaves out. The full
/// description (focused: a card; Select reads it whole), the facts three to
/// a line
/// — when, how long, genres, who made it; original title, language,
/// country, rating, network; budget and box office — every rating source
/// shown, and the studios as logos that open their titles.
struct DetailAbout: View {
    let meta: MetaItem
    let about: TMDBService.About?
    let facts: TMDBService.TitleFacts?
    let releaseDate: String?
    let contentRating: String?
    let language: String?
    let ratings: MDBListRatings?
    let settings: MDBListSettings
    let companies: [TMDBService.Company]
    let onExpand: () -> Void
    let onSelectCompany: (TMDBService.Company) -> Void
    let onFocus: (Bool) -> Void
    /// Goes up: focus onto the description (else the first logo).
    var focusRequest = 0

    private enum Focus: Hashable { case description, company(TMDBService.Company) }
    @FocusState private var focus: Focus?

    static let descriptionWidth: CGFloat = 700
    /// The card's text inset: the text itself lines up with the heading.
    private static let inset: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            if let text = meta.description, !text.isEmpty {
                // Plain text at rest; focused, the plate comes up around it.
                Button(action: onExpand) {
                    Text(text)
                        .font(.system(size: 24))
                        .lineSpacing(5)
                        .lineLimit(9)
                        .frame(width: Self.descriptionWidth, alignment: .topLeading)
                        .padding(Self.inset)
                }
                .buttonStyle(AboutCardStyle(rest: 0))
                .padding(.leading, -Self.inset)
                .padding(.top, -Self.inset)
                .focused($focus, equals: .description)
            }
            VStack(alignment: .leading, spacing: 36) {
                factGrid
                let entries = MDBListRatingsRow.entries(ratings, settings: settings, imdbFallback: meta.imdbRating)
                if !entries.isEmpty {
                    labelled("Ratings") {
                        MDBListRatingsRow(entries: entries, inline: true, chips: .chips)
                    }
                }
                if !companies.isEmpty {
                    labelled(companies.contains(where: \.isNetwork) ? "Network & Studios" : "Studios") {
                        HStack(spacing: 20) {
                            ForEach(companies.prefix(6), id: \.self) { company in
                                Button { onSelectCompany(company) } label: { StudioLogo(company: company) }
                                    .buttonStyle(AboutCardStyle(corner: 12, rest: 0.9))
                                    .focused($focus, equals: .company(company))
                            }
                        }
                    }
                    // Right from the description reaches the logos, wherever
                    // they sit below it.
                    .focusSection()
                }
            }
        }
        .padding(.trailing, Spotlight.screenInset)
        .onChange(of: focus) { _, now in onFocus(now != nil) }
        .onChange(of: focusRequest) { _, _ in
            if meta.description?.isEmpty == false { focus = .description }
            else if let first = companies.first { focus = .company(first) }
        }
    }

    /// The facts, three to a line: the name small above, the value.
    private var factGrid: some View {
        let facts = leftFacts + rightFacts
        let rows = stride(from: 0, to: facts.count, by: 3).map { Array(facts[$0 ..< min($0 + 3, facts.count)]) }
        return Grid(alignment: .topLeading, horizontalSpacing: 48, verticalSpacing: 26) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r], id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(label.uppercased())
                                .font(.system(size: 17, weight: .semibold))
                                .tracking(1)
                                .foregroundStyle(Color.white.opacity(0.5))
                            Text(value)
                                .font(.system(size: 24))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .lineLimit(2)
                        }
                        .frame(width: 290, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Facts

    private var leftFacts: [(String, String)] {
        var rows: [(String, String)] = []
        if meta.isSeries {
            if let years = airYears { rows.append(("Aired", years)) }
            if let size = SeriesEpisodes.size(of: meta) {
                rows.append(("Episodes", "\(size.episodes) in \(size.seasons) \(size.seasons == 1 ? "season" : "seasons")"))
            }
        } else {
            if let released = DateFormat.releaseDate(releaseDate) ?? meta.releaseInfo { rows.append(("Released", released)) }
            if let minutes = facts?.runtimeMinutes, minutes > 0 { rows.append(("Runtime", Self.duration(minutes))) }
        }
        if let genres = meta.genres, !genres.isEmpty { rows.append(("Genres", genres.joined(separator: ", "))) }
        // "Director: …" / "Creators: …" as its own row.
        if let line = facts?.creatorLine, let colon = line.firstIndex(of: ":") {
            rows.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return rows
    }

    private var rightFacts: [(String, String)] {
        var rows: [(String, String)] = []
        if let original = about?.originalTitle, !original.isEmpty, original != meta.name {
            rows.append(("Original Title", original))
        }
        if let code = language?.lowercased(), let name = Locale.current.localizedString(forLanguageCode: code) {
            rows.append(("Language", name))
        }
        if let countries = about?.countries, !countries.isEmpty {
            rows.append((countries.count == 1 ? "Country" : "Countries", countries.prefix(3).joined(separator: ", ")))
        }
        if let rating = contentRating, !rating.isEmpty { rows.append(("Rated", rating)) }
        if let networks = about?.networks, !networks.isEmpty {
            rows.append(("Network", networks.prefix(2).joined(separator: ", ")))
        }
        // Studios with no logo to show: by name.
        if companies.isEmpty, let studios = about?.studios, !studios.isEmpty {
            rows.append(("Studios", studios.prefix(3).joined(separator: ", ")))
        }
        if let budget = about?.budget { rows.append(("Budget", Self.money(budget))) }
        if let revenue = about?.revenue { rows.append(("Box Office", Self.money(revenue))) }
        return rows
    }

    /// "2016 – 2024", "2016 – Present" while it runs.
    private var airYears: String? {
        guard let first = (releaseDate ?? meta.releaseInfo).map({ String($0.prefix(4)) }) else { return nil }
        if facts?.status == "ONGOING" { return "\(first) – Present" }
        guard let last = about?.lastAirDate.map({ String($0.prefix(4)) }), last != first else { return first }
        return "\(first) – \(last)"
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 17, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.white.opacity(0.5))
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

/// A studio's logo on a light plate (logos are drawn for light ground).
private struct StudioLogo: View {
    let company: TMDBService.Company

    var body: some View {
        RemoteImage(url: company.logoURL, contentMode: .fit, maxDimension: 140)
            .frame(width: 130, height: 50)
            .frame(width: 160, height: 74)
    }
}

/// The About section's focusable cards: a faint plate at rest, the white
/// highlight (dark text) when focused, a slight lift.
private struct AboutCardStyle: ButtonStyle {
    var corner: CGFloat = 24
    /// The plate's white at rest.
    var rest: Double = 0.08

    func makeBody(configuration: Configuration) -> some View { Card(configuration: configuration, style: self) }

    private struct Card: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let style: AboutCardStyle

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? FlatControl.contentOnFocus : Color.white.opacity(0.85))
                .background(RoundedRectangle(cornerRadius: style.corner, style: .continuous)
                    .fill(isFocused ? FlatControl.focus : Color.white.opacity(style.rest)))
                .scaleEffect(isFocused ? 1.04 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 16, y: 8)
                .animation(.smooth(duration: 0.2), value: isFocused)
        }
    }
}

/// The description in full, over Details (the About card's Select).
struct DetailAboutFull: View {
    let title: String
    let text: String
    let onClose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            Button(action: onClose) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(title)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(Color.white)
                    Text(text)
                        .font(.system(size: 28))
                        .lineSpacing(6)
                        .foregroundStyle(Color.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(56)
                .frame(maxWidth: 1240, alignment: .leading)
                .background {
                    Color.clear
                        .liquidGlass(in: shape)
                }
            }
            .buttonStyle(PlainNoChromeStyle())
        }
        .onExitCommand(perform: onClose)
    }
}

/// A button with no chrome of its own (the card draws everything).
private struct PlainNoChromeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
