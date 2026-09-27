import SwiftUI

/// The title block shared by Home's billboard and the Detail page's
/// overview: logo (or name), one meta line, the description. Same sizes,
/// same place on screen, so opening Details from the billboard is a swap of
/// only what's around it — the Home chrome goes, the Detail buttons come.
///
/// Laid out from the LOGO: its bottom edge on the screen's vertical centre,
/// then — at fixed distances — the meta line, the ratings row and the
/// Detail page's buttons (the billboard's dots). The description is left
/// out for now (`showsDescription`), so the block never changes height and
/// everything, the focus included, always sits in the same place.
/// Everything else the Detail page has (director, parental guide) lives on
/// its More page.
///
/// While a trailer plays the text fades out; the logo and buttons stay.
enum TitleBlock {
    static let logoWidth: CGFloat = 520
    /// Logo and text title share this slot, bottom-aligned, so a title with
    /// artwork and one without put the meta line in the same place.
    static let logoHeight: CGFloat = 180
    static let spacing: CGFloat = OrivioSpacing.lg
    static let descriptionSize: CGFloat = 25
    /// Narrow enough to read comfortably (~70–80 characters a line).
    static let descriptionWidth: CGFloat = 820
    /// Description cap — keeps the logo from climbing too high.
    static let descriptionLines = 6
    /// The description is left out for now: without it the block always
    /// has the same height, so it sits in exactly the same place.
    static let showsDescription = false
    /// The meta line's height (for the fixed layout below).
    static let metaLineHeight: CGFloat = 32
    /// The button row's height (the Detail page's buttons; the billboard's
    /// dots sit in the same row).
    static let buttonHeight: CGFloat = 60
    /// The ratings row (MDBList badges) between the meta line and the
    /// description — kept on the billboard too (empty), so both screens
    /// put the description in the same place.
    static let ratingsHeight: CGFloat = 32

    /// The "▾ Next" hint under the block, on both screens. Low: neither
    /// the billboard nor the overview shows a preview row under it.
    static let hintBottomInset: CGFloat = 52
    static func hintY(screenHeight: CGFloat) -> CGFloat {
        screenHeight - hintBottomInset - Spotlight.labelHeight
    }
    /// The "▴ Previous" hint's top: as far from the top edge as the bottom
    /// one is from the bottom — every hint sits at one of these two spots,
    /// whatever the section's content.
    static let topHintY: CGFloat = hintBottomInset
    /// THE anchor: the logo's bottom edge on the screen's vertical centre
    /// (on both screens). Below it, at fixed distances: the meta line, the
    /// ratings row — the block's bottom — then the button row (the
    /// billboard's dots).
    static func logoBottomY(screenHeight: CGFloat) -> CGFloat { screenHeight / 2 }

    /// Where the block's bottom edge sits (the ratings row's bottom).
    static func bottomY(screenHeight: CGFloat) -> CGFloat {
        logoBottomY(screenHeight: screenHeight) + spacing + metaLineHeight + spacing + ratingsHeight
    }

    /// Where the button row (the billboard's dots) starts.
    static func extrasY(screenHeight: CGFloat) -> CGFloat {
        bottomY(screenHeight: screenHeight) + spacing
    }

    /// THE meta line — Home's caption, the billboard and the Detail page
    /// alike: Type • Genre • Years • Size (seasons / episodes; a movie's
    /// runtime) • ★ Rating. Missing pieces are skipped.
    /// `seriesSize`: when the caller knows the show's size better (Home
    /// fetches it from TMDB for catalog entries without an episode list).
    static func metaSegments(for item: MetaItem, seriesSize: String? = nil) -> [String] {
        var segments: [String] = []
        segments.append(item.isSeries ? "Series"
                        : item.type == "movie" ? "Movie" : item.type.capitalized)
        if let genre = primaryGenre(item) { segments.append(genre) }
        // Series keep their range — it says whether the show is still
        // running — but tidied up (see `yearText`).
        if let year = yearText(item.releaseInfo) { segments.append(year) }
        if item.isSeries {
            if let size = seriesSize ?? seriesSizeText(item) { segments.append(size) }
        } else if let runtime = item.runtime, !runtime.isEmpty {
            segments.append(runtime)
        }
        if let rating = item.imdbRating, !rating.isEmpty {
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
    static let size: CGFloat = 18
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
                .font(.system(size: Self.size, weight: .semibold))
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
            .font(.system(size: Self.size, weight: .semibold))
            .offset(y: up ? -push : push)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

/// The rows' ‹ › (Home and the Detail page's episodes alike): a small
/// glass circle; pressed, it gives a little and brightens.
struct GlassChevron: View {
    let symbol: String
    var pressed = false
    var size: CGFloat = Spotlight.chevronCircle
    var icon: CGFloat = Spotlight.chevronIcon

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: icon, weight: .bold))
            .foregroundStyle(AppGlass.text)
            .frame(width: size, height: size)
            .glassSurface(in: Circle())
            .overlay {
                Circle().fill(Color.white.opacity(pressed ? Spotlight.chevronPressGlow : 0))
            }
            .scaleEffect(pressed ? Spotlight.chevronPressScale : 1)
            .allowsHitTesting(false)
    }
}

struct TitleBlockView: View {
    @EnvironmentObject private var theme: ThemeManager
    let logo: String?
    let name: String
    let metaSegments: [String]
    let description: String?
    /// The ratings row (the Detail page's MDBList badges; none on the
    /// billboard — its space is kept either way).
    var ratings: AnyView? = nil
    /// A trailer is playing: the meta line, ratings and description step
    /// aside (their space is kept, so the logo doesn't move).
    var descriptionHidden = false
    /// Off: just the text (the caller places the logo itself).
    var showsLogo = true
    /// Overrides `TitleBlock.descriptionLines`.
    var descriptionLineLimit: Int? = nil

    /// The title as text — when there's no logo, or it failed to load.
    private var nameText: some View {
        Text(name)
            .font(FusionType.heroTitle(theme.font))
            .foregroundStyle(theme.palette.textPrimary)
            .lineLimit(2)
            .frame(maxWidth: 900, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TitleBlock.spacing) {
            Group {
                if let logo {
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
            .frame(height: showsLogo ? nil : 0)
            .clipped()

            Group {
                MetaLine(segments: metaSegments)
                (ratings ?? AnyView(EmptyView()))
                    .frame(height: TitleBlock.ratingsHeight, alignment: .leading)
            }
            .opacity(descriptionHidden ? 0 : 1)
            .animation(.easeInOut(duration: 0.4), value: descriptionHidden)

            if TitleBlock.showsDescription, let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: TitleBlock.descriptionSize))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(descriptionLineLimit ?? TitleBlock.descriptionLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: TitleBlock.descriptionWidth, alignment: .leading)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                    .opacity(descriptionHidden ? 0 : 1)
                    .animation(.easeInOut(duration: 0.4), value: descriptionHidden)
            }
        }
    }
}
