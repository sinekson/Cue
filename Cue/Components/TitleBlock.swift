import SwiftUI

/// The title block shared by Home's billboard and the Detail page's
/// overview: logo; the ratings row; the description (up to 5 lines, in a
/// fixed room); the meta line (the catalogs' own, without the rating);
/// the badges row (ENDED / ONGOING chips); on Details only, the buttons at a
/// fixed spot below — the same for every title.
///
/// The logo sits at a fixed spot — so for every title the
/// logo, the rows, the buttons and the focus are in the same place.
///
/// While a trailer plays the text fades out; the logo and buttons stay.
enum TitleBlock {
    static let logoWidth: CGFloat = 560
    /// Logo and text title share this slot, bottom-aligned.
    static let logoHeight: CGFloat = 160

    /// Logo → the ratings row (MDBList icons + scores).
    static let logoToRatings: CGFloat = 20
    static let ratingsHeight: CGFloat = 36
    static let ratingsToDescription: CGFloat = 20

    /// The description: at most `descriptionLines`, in a FIXED room — the
    /// meta line and badges below sit at fixed spots (an anchor); a short
    /// text leaves room between it and the meta line.
    static let descriptionSize: CGFloat = 26
    static let descriptionOpacity: Double = 0.82
    static let descriptionLineSpacing: CGFloat = 6
    static let descriptionWidth: CGFloat = 920
    static let descriptionLines = 5
    /// One line at `descriptionSize` with its spacing.
    static let descriptionLineHeight: CGFloat = 37
    static var descriptionMaxHeight: CGFloat { CGFloat(descriptionLines) * descriptionLineHeight }
    static let descriptionToMeta: CGFloat = 20

    static let metaSize: CGFloat = 25
    static let metaHeight: CGFloat = 34
    static let metaToBadges: CGFloat = 10
    /// The badges row (outlined chips).
    static let badgesHeight: CGFloat = 34

    /// Badges (after the LONGEST description) → the button row (Details).
    static let badgesToButtons: CGFloat = 32
    /// The button row's height (the Detail page's buttons).
    static let buttonHeight: CGFloat = 60

    /// The "▾ Next" hint under the block, on both screens.
    static let hintBottomInset: CGFloat = 52
    static func hintY(screenHeight: CGFloat) -> CGFloat {
        screenHeight - hintBottomInset - Spotlight.labelHeight
    }
    /// The "▴ Previous" hint's top: as far from the top edge as the bottom
    /// one is from the bottom.
    static let topHintY: CGFloat = hintBottomInset
    /// THE anchor: the logo slot's top, this far above the "▾" hint (where
    /// it was with the longer block, so the logo didn't move).
    static let logoTopAboveHint: CGFloat = 713

    static func topY(screenHeight: CGFloat) -> CGFloat {
        hintY(screenHeight: screenHeight) - logoTopAboveHint
    }

    /// Where the button row (Details) starts: a FIXED spot below the
    /// badges — the same for every title.
    static func buttonsY(screenHeight: CGFloat) -> CGFloat {
        topY(screenHeight: screenHeight) + logoHeight + logoToRatings + ratingsHeight
            + ratingsToDescription + descriptionMaxHeight + descriptionToMeta
            + metaHeight + metaToBadges + badgesHeight + badgesToButtons
    }

    /// THE meta line — Home's caption, the billboard and the Detail page
    /// alike: Type • Genre • Years • Size (seasons / episodes; a movie's
    /// runtime) • ★ Rating. Missing pieces are skipped.
    /// `seriesSize`: when the caller knows the show's size better (Home
    /// fetches it from TMDB for catalog entries without an episode list).
    /// `includesRating`: off in the title block (its ratings row has them).
    static func metaSegments(for item: MetaItem, seriesSize: String? = nil,
                             includesRating: Bool = true, startYearOnly: Bool = false) -> [String] {
        var segments: [String] = []
        segments.append(item.isSeries ? "Series"
                        : item.type == "movie" ? "Movie" : item.type.capitalized)
        if let genre = primaryGenre(item) { segments.append(genre) }
        // Series keep their range — it says whether the show is still
        // running — but tidied up (see `yearText`).
        if startYearOnly, let years = catalogYears(item) {
            // (The status badge carries the rest: ONGOING / ENDED + year.)
            segments.append(years.start)
        } else if let year = yearText(item.releaseInfo) { segments.append(year) }
        if item.isSeries {
            if let size = seriesSize ?? seriesSizeText(item) { segments.append(size) }
        } else if let runtime = item.runtime, !runtime.isEmpty {
            segments.append(runtime)
        }
        if includesRating, let rating = item.imdbRating, !rating.isEmpty {
            segments.append("\(ratingPrefix)\(rating)")
        }
        return segments
    }

    /// Prefix of the rating in the meta line.
    static let ratingPrefix = "★ "
    /// How a still-running series shows its years ("{start}" = first year).
    static let ongoingYearFormat = "{start}–Present"
    /// Genres too generic to be THE genre (anime are all "Animation") —
    /// skipped unless they're the only one.
    static let genericGenres: Set<String> = ["Animation", "Anime"]

    /// ONE genre: the first that says something.
    static func primaryGenre(_ item: MetaItem) -> String? {
        guard let genres = item.genres, !genres.isEmpty else { return nil }
        return genres.first { !genericGenres.contains($0) } ?? genres.first
    }

    /// A series' status from the catalog's year field (there at once, no
    /// request): "2016-" → RETURNING, "2016-2020" → ENDED 2020. Nil for
    /// movies and anything that isn't a clear range. Only the stand-in until
    /// the real status is known (`FixedFocusShowInfo.status`): the catalog's
    /// last year is when episodes last aired, so a show between seasons can
    /// read as ended here.
    static func catalogStatus(_ item: MetaItem) -> String? {
        guard let years = catalogYears(item) else { return nil }
        return years.end.map { "ENDED \($0)" } ?? "RETURNING"
    }

    /// A series' years from the catalog: its first, and its last if the
    /// range is closed (nil: open). Nil when the field isn't a clear range.
    static func catalogYears(_ item: MetaItem) -> (start: String, end: String?)? {
        guard item.isSeries, let raw = item.releaseInfo?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = raw.split(omittingEmptySubsequences: false,
                              whereSeparator: { "-–—".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].count == 4, Int(parts[0]) != nil else { return nil }
        if parts[1].isEmpty { return (parts[0], nil) }
        return parts[1].count == 4 && Int(parts[1]) != nil ? (parts[0], parts[1]) : nil
    }

    /// Tidies the catalog's year field:
    /// - "2016-2020" → "2016–2020" (a proper en dash)
    /// - "2016-"     → "2016–Present" (see `ongoingYearFormat`)
    /// - "2016-2016" → "2016"
    /// Anything that isn't a year or a year range is shown unchanged.
    static func yearText(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(omittingEmptySubsequences: false,
                              whereSeparator: { "-–—".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].count == 4, Int(parts[0]) != nil else { return raw }
        let start = parts[0], end = parts[1]
        if end.isEmpty { return ongoingYearFormat.replacingOccurrences(of: "{start}", with: start) }
        guard end.count == 4, Int(end) != nil else { return raw }
        return start == end ? start : "\(start)–\(end)"
    }

    /// "4 Seasons" for a multi-season show, "8 Episodes" for a single
    /// season (a season count of 1 says little), from the title's own
    /// episode list.
    static func seriesSizeText(_ item: MetaItem, seasons: Int? = nil, episodes: Int? = nil) -> String? {
        let seasons = seasons ?? item.regularSeasons.count
        let episodes = episodes ?? (item.videos ?? []).filter { ($0.season ?? 0) > 0 }.count
        if seasons > 1 { return "\(seasons) Seasons" }
        if episodes > 0 { return episodes == 1 ? "1 Episode" : "\(episodes) Episodes" }
        return seasons == 1 ? "1 Season" : nil
    }

    /// First 4-digit year found in a date/string (for the year-only display).
    static func firstYear(in text: String) -> String? {
        let digits = Array(text)
        for i in 0...(max(0, digits.count - 4)) where i + 4 <= digits.count {
            let slice = String(digits[i..<i + 4])
            if slice.allSatisfy(\.isNumber), let year = Int(slice), (1900...2100).contains(year) {
                return slice
            }
        }
        return nil
    }
}

/// The quiet signpost to the next (or previous) section — the SAME on
/// Home's billboard and every Detail page section: centred, small capitals
/// with wide spacing, half-white, a thin chevron that bobs gently now and
/// then ("there's more this way"). No glass: it's navigation, not content,
/// and stays quieter than the rows' names.
struct SectionHint: View {
    let title: String
    /// Points up (to the section above): chevron on top.
    var up = false
    /// Down/Up was pressed: the chevron gives a short push that way.
    var pressed = false
    /// E.g. while a trailer plays: steps aside.
    var hidden = false

    /// Left-aligned (the chevron at the content margin, the text after
    /// it) or centred on screen. Every hint follows this.
    static let leftAligned = true
    /// Subtle through its weight and brightness, not by being tiny: small
    /// spaced capitals read about a size larger than their point size.
    static let size: CGFloat = 21
    static let weight: Font.Weight = .medium
    static let tracking: CGFloat = 2.5
    static let opacity: Double = 0.55
    /// The idle bob: how far, how often.
    static let bob: CGFloat = 5
    static let bobEvery: Duration = .seconds(3.5)

    @State private var bobbing = false

    var body: some View {
        // The chevron (the text's size) first, at the content margin — it
        // lines up with the content's left edge; the text follows.
        HStack(spacing: 12) {
            chevron
            Text(title.uppercased())
                .font(.system(size: Self.size, weight: Self.weight))
                .tracking(Self.tracking)
                .lineLimit(1)
        }
        .foregroundStyle(Color.white.opacity(Self.opacity))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        .opacity(hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.4), value: hidden)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.bobEvery)
                withAnimation(.easeInOut(duration: 0.45)) { bobbing = true }
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation(.easeInOut(duration: 0.5)) { bobbing = false }
            }
        }
        .allowsHitTesting(false)
    }

    /// Placed across a full-width row: at the content margin, or centred.
    static func place<V: View>(_ hint: V) -> some View {
        hint
            .padding(.leading, leftAligned ? Spotlight.screenInset : 0)
            .frame(maxWidth: .infinity, alignment: leftAligned ? .leading : .center)
    }

    private var chevron: some View {
        let push = (bobbing ? Self.bob : 0) + (pressed ? Self.bob * 1.4 : 0)
        return Image(systemName: up ? "chevron.up" : "chevron.down")
            .font(.system(size: Self.size, weight: Self.weight))
            .offset(y: up ? -push : push)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

/// Trailer mode, the same on the billboard and Details: after `delay` of
/// rest (on the billboard; on Details, on Play) the trailer plays WITH
/// SOUND and everything vanishes but what you can act on — the navigation
/// ("▾ Continue Watching" and the dots / "▾ Episodes") and, on Details,
/// Play. A move that navigates stops it (Left/Right/Down; on Details moving
/// off Play); Up or Back only brings the page back, the trailer running on
/// muted. Nothing vanishes before the video actually plays — a failed load
/// changes nothing.
enum TrailerMode {
    /// Automatic trailers (billboard, the rows' boxes, Details) — OFF until
    /// the feature is finished (it misbehaved). The Watch Trailer button
    /// (the full-screen player) is separate and still works.
    static let enabled = false
    static let delay: TimeInterval = 3
    /// The page going / coming back.
    static let fade: Animation = .easeInOut(duration: 0.4)
    /// The scrim while the trailer has the screen (enough for the hints).
    static let scrimOpacity: Double = 0.4
}

/// The billboard ⇄ Details swap. The title block, backdrop and scrim are
/// identical on both screens and never move; only what differs does. Each
/// screen animates ITS OWN parts: the leaving screen's go out (`out`), the
/// screen changes without any system animation, the arriving screen's come
/// in (`in`). Back runs the same two halves the other way round, so the
/// reverse is exact by construction:
/// - Home: the top bar moves up and fades; "▾ Continue Watching" and the
///   dots move down and fade.
/// - Details: its backdrop leans in (`depthScale`) and darkens a step
///   (`depthDim`); the buttons fade in place at their spot below the badges;
///   "▾ Episodes" comes down into place from a little above (the bottom
///   moves one way, like a flip).
@MainActor
final class ModeSwap: ObservableObject {
    static let shared = ModeSwap()

    /// What Details' Play says, as the billboard knew it ("Play S2:E3"):
    /// until its own episode list is in, Play doesn't change its label.
    var billboardPlayTitle: String?
    /// Home's top bar is out for the billboard's trailer (see `TrailerMode`).
    /// It can't take focus then either: Up brings the page back instead.
    @Published var trailerChromeOut = false
    /// The title Details was opened for from the billboard — only that page
    /// plays its half of the swap (and returns with it).
    var billboardItemID: String?
    /// What the billboard showed for it — Details starts with these, so its
    /// title block is identical from the first frame.
    var billboardRatings: MDBListRatings?
    var billboardFacts: TMDBService.TitleFacts?
    /// The meta line's series size as the billboard showed it.
    var billboardSeriesSize: String?
    /// The background's colours under the billboard — Details starts on them.
    var billboardTint: (first: Color?, second: Color?) = (nil, nil)

    /// From Select on the billboard or a card until Details is up: Home
    /// holds still (no focus moves), and a Select, Back or Down pressed
    /// meanwhile waits for Details (`heldPress`) — none is lost, none acts
    /// on Home underneath.
    var handingOver = false {
        didSet { if handingOver { heldPress = nil } }
    }
    enum HeldPress { case play, back, down }
    var heldPress: HeldPress?

    /// The old swap's going half — only its timing is still used, for the
    /// fades below.
    static let outDuration: Double = 0.16
    static let handoverDelay: Double = outDuration * 0.75
    /// Fades run on their own, linear — so the movement stays visible.
    static let fadeOut: Animation = .linear(duration: handoverDelay)
    static let fadeIn: Animation = .linear(duration: 0.18)
    /// How far the parts travel as they go / come.
    static let lift: CGFloat = 20
    /// Depth: Details is a step "into" the title — its backdrop leans in
    /// (scales up). Billboard (lightest) → overview → Episodes (darkest).
    static let depthScale: CGFloat = 1.06
    /// The page may load and re-render after this.
    static let swapSettle: Double = 0.8

    /// The top bar's away/back move (trailers, the sidebar).
    static let swapDuration: Double = 0.5
    static let swapControlPoints = (CGPoint(x: 0.35, y: 0), CGPoint(x: 0.15, y: 1))
    static var swap: Animation {
        .timingCurve(swapControlPoints.0.x, swapControlPoints.0.y,
                     swapControlPoints.1.x, swapControlPoints.1.y, duration: swapDuration)
    }

    /// The backdrop at a depth progress `p` (0 = the billboard, 1 = Details).
    static func depthScale(_ p: CGFloat) -> CGFloat { 1 + (depthScale - 1) * p }
    /// The top bar moves up (and fades) this far.
    static let chromeTravel: CGFloat = 80
}

struct TitleBlockView: View {
    @EnvironmentObject private var theme: ThemeManager
    let item: MetaItem
    /// TMDB's extras (creator, status, …); nil until loaded — their room
    /// is kept either way.
    var facts: TMDBService.TitleFacts? = nil
    /// The series' size ("4 Seasons"), when the caller knows it better
    /// than the catalog entry does.
    var seriesSize: String? = nil
    /// A trailer is playing: everything but the logo steps aside (its
    /// space is kept, so nothing moves).
    var textHidden = false
    /// Off: just the text (the caller places the logo itself).
    var showsLogo = true
    /// The ratings row (under the logo); its room is kept either way.
    var ratings: AnyView? = nil

    /// The title as text — when there's no logo, or it failed to load.
    private var nameText: some View {
        Text(item.name)
            .font(FusionType.heroTitle(theme.font))
            .foregroundStyle(theme.palette.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.74)
            .frame(maxWidth: TitleBlock.logoWidth, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let logo = item.logo {
                    // A logo that can't be loaded falls back to the name.
                    RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading,
                                maxDimension: TitleBlock.logoWidth, showsPlaceholder: false,
                                fallback: AnyView(nameText))
                        // Grounds a white logo on both light and dark art.
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                        .frame(width: TitleBlock.logoWidth)
                } else {
                    nameText
                }
            }
            .frame(height: TitleBlock.logoHeight, alignment: .bottomLeading)
            .opacity(showsLogo ? 1 : 0)

            VStack(alignment: .leading, spacing: 0) {
                (ratings ?? AnyView(EmptyView()))
                    .frame(height: TitleBlock.ratingsHeight, alignment: .leading)
                    .padding(.top, TitleBlock.logoToRatings)
                    .padding(.bottom, TitleBlock.ratingsToDescription)

                Text(item.description ?? "")
                    .font(.system(size: TitleBlock.descriptionSize))
                    .foregroundStyle(Color.white.opacity(TitleBlock.descriptionOpacity))
                    .lineSpacing(TitleBlock.descriptionLineSpacing)
                    .lineLimit(TitleBlock.descriptionLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: TitleBlock.descriptionWidth, alignment: .leading)
                    // Its full room, whatever its length: the meta line
                    // below sits at a fixed spot (a visual anchor) — the
                    // room a short text leaves is above it.
                    .frame(height: TitleBlock.descriptionMaxHeight, alignment: .topLeading)
                    .padding(.bottom, TitleBlock.descriptionToMeta)

                Text(TitleBlock.metaSegments(for: item, seriesSize: seriesSize, includesRating: false)
                        .joined(separator: "  •  "))
                    .font(.system(size: TitleBlock.metaSize, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(height: TitleBlock.metaHeight, alignment: .leading)
                    .padding(.bottom, TitleBlock.metaToBadges)

                HStack(spacing: 12) {
                    ForEach(badges, id: \.self) { TitleBadge(text: $0) }
                }
                .frame(height: TitleBlock.badgesHeight, alignment: .leading)
            }
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .opacity(textHidden ? 0 : 1)
            .animation(.easeInOut(duration: 0.4), value: textHidden)
        }
    }

    /// The badges row — the title's status for now (ENDED / ONGOING);
    /// each its own outlined chip.
    private var badges: [String] {
        [facts?.status].compactMap { $0 }
    }
}

/// One badge in the badges row: a small outlined chip.
struct TitleBadge: View {
    @ObservedObject private var probe = RenderProbe.shared
    let text: String

    /// Render Lab → Badge: outlined (the original), the app's glass, or a
    /// flat faint fill.
    enum Style: String, CaseIterable {
        case outline, glass, fill
        var displayName: String {
            switch self {
            case .outline: return "Outlined"
            case .glass: return "Liquid Glass"
            case .fill: return "Flat fill"
            }
        }
    }

    var body: some View {
        let style = Style(rawValue: probe.flags.badgeStyle) ?? .outline
        // No taller than a line of the text beside it: capitals as high
        // as that text's lowercase letters, in a box of about 28 pt.
        let label = Text(text)
            .font(.system(size: 17, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color.white.opacity(0.85))
            // (The rating chips' height — see `MDBListRatingsRow`.)
            .frame(height: 21)
        switch style {
        case .outline:
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1.25))
        case .glass:
            // (Was the top bar's glass; in the page everything is flat.)
            label
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(FlatControl.rest, in: Capsule())
        case .fill:
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

