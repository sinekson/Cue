import SwiftUI
import UIKit

// MARK: - Model

/// One episode as the Detail page's episode row shows it: everything
/// already worked out (the row — Home's cards, `FixedFocusRows` — only draws).
struct EpisodeRowItem: Equatable {
    let id: String
    let season: Int
    let number: Int
    /// The episode's title (under the card).
    let title: String
    /// Under the title: its length, when it aired / airs.
    let facts: String
    let image: String?
    /// The card's state line — Continue Watching's.
    let state: EpisodeRowState
}

/// A card's state line, as on Continue Watching's cards: which episode on
/// the left; a progress bar and the time left, or a status on the right.
struct EpisodeRowState: Equatable {
    let label: String
    /// In progress: how far (0…1), and "20m left".
    var progress: Double?
    var remaining: String?
    /// Not in progress: "Watched" (with a check), "Airs Fri", "45m".
    var status: String?
    var watched = false
}

// MARK: - Blurred backdrop

/// A backdrop blurred ONCE into a still image (a small copy — a blur has no
/// detail to keep — scaled up on screen): no live blur filter, nothing
/// recomputed per frame. Kept per picture and strength.
@MainActor
enum BlurredBackdrop {
    private static let cache = NSCache<NSString, UIImage>()
    /// The working width.
    private static let width: CGFloat = 640
    /// The blur's radius, in the working width's pixels.
    private static let strength: Double = 20

    /// The blurred picture if it's already made (no wait).
    static func cached(for url: String?) -> UIImage? {
        url.flatMap { cache.object(forKey: "\($0)|\(strength)" as NSString) }
    }

    static func image(for url: String?) async -> UIImage? {
        guard let url else { return nil }
        let key = "\(url)|\(strength)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var source = await ImageCache.shared.diskImage(for: url, budget: width)
        if source == nil, let remote = URL(string: url),
           let data = try? await ImageCache.shared.download(remote) {
            ImageCache.shared.insertData(data, for: url)
            source = ImageCache.decodeDownsampled(data, budget: width)
        }
        guard let cgImage = source?.cgImage else { return nil }
        let blurred = await Task.detached(priority: .utility) { () -> UIImage? in
            let input = CIImage(cgImage: cgImage)
            let output = input.clampedToExtent()
                .applyingGaussianBlur(sigma: strength)
                .cropped(to: input.extent)
            let context = CIContext()
            guard let result = context.createCGImage(output, from: input.extent) else { return nil }
            return UIImage(cgImage: result)
        }.value
        if let blurred { cache.setObject(blurred, forKey: key) }
        return blurred
    }
}

// MARK: - Progress map

/// Where you are in the season, under the episode row: one tick per
/// episode — watched ones filled, the one in the box highlighted — and
/// "Season 2 • 8 of 12 watched". Long seasons: the ticks narrow; past
/// `barFrom` episodes they merge into one bar with a marker.
struct SeasonProgressMap: View {
    struct Tick: Equatable {
        let id: String
        let watched: Bool
        let current: Bool
    }

    let ticks: [Tick]
    let label: String
    /// INLINE (under the row's name or its season buttons, Details): the
    /// ticks, then the label after them on the same line — `width` the whole
    /// line, the label's end at its end.
    var inline = false
    var width: CGFloat = Self.width

    /// The map's width: the box's text column.
    static let width = FixedFocusMetrics.boxWidth - 2 * FixedFocusMetrics.textIndent
    /// Inline: an episode card's width — the label ends at the first
    /// card's right edge below. (The line starts at the text indent.)
    static let inlineWidth = FixedFocusMetrics.landscapeWidth(height: FixedFocusMetrics.destinationTileHeight)
        - FixedFocusMetrics.textIndent
    /// Inline: between the ticks and the label.
    static let labelGap: CGFloat = 16
    static let height: CGFloat = 8
    static let gap: CGFloat = 4
    static let barFrom = 60

    /// Over this many episodes: one bar (inline sooner — less room).
    private var asBar: Bool { ticks.count > (inline ? 36 : Self.barFrom) }

    /// The ticks' (or the bar's) width: inline, what the label leaves.
    private var ticksWidth: CGFloat {
        guard inline else { return width }
        let font = UIFont.systemFont(ofSize: Self.labelSize, weight: .medium)
        let label = (label as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return width - label - Self.labelGap
    }
    static let labelSize: CGFloat = 21

    var body: some View {
        Group {
            if inline {
                HStack(spacing: Self.labelGap) {
                    if asBar { bar } else { row }
                    labelText
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    labelText
                    if asBar { bar } else { row }
                }
            }
        }
        .animation(GlassPill.glide, value: ticks)
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: Self.labelSize, weight: .medium))
            .foregroundStyle(AppGlass.textMuted)
            .lineLimit(1)
            .fixedSize()
    }

    private var row: some View {
        let n = max(ticks.count, 1)
        let tick = (ticksWidth - CGFloat(n - 1) * Self.gap) / CGFloat(n)
        return HStack(spacing: Self.gap) {
            ForEach(ticks, id: \.id) { t in
                Capsule()
                    .fill(Color.white.opacity(t.current ? 1 : t.watched ? 0.62 : 0.2))
                    // (Inline: always the full width — the label stays put
                    // from season to season.)
                    .frame(width: inline ? max(tick, 3) : max(min(tick, 44), 3),
                           height: t.current ? Self.height + 4 : Self.height)
            }
        }
        .frame(height: Self.height + 4)
    }

    /// Many episodes: the share watched as one bar, the episode in the box
    /// as a marker on it.
    private var bar: some View {
        let width = ticksWidth
        let watched = CGFloat(ticks.filter(\.watched).count) / CGFloat(max(ticks.count, 1))
        let at = CGFloat(ticks.firstIndex(where: \.current) ?? 0) / CGFloat(max(ticks.count - 1, 1))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.2))
                .frame(width: width, height: Self.height)
            Capsule().fill(Color.white.opacity(0.62))
                .frame(width: max(width * watched, Self.height), height: Self.height)
            Capsule().fill(Color.white)
                .frame(width: 6, height: Self.height + 8)
                .offset(x: (width - 6) * at)
        }
        .frame(width: width, height: Self.height + 8, alignment: .leading)
    }
}
