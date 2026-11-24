import SwiftUI

/// A background's colours as a strip, each as wide as its share, darkest
/// first, at the background's saturation (Settings 2's rows).
struct BackgroundColours: View {
    static let size = CGSize(width: 96, height: 56)
    let entry: BackgroundPicks.Entry?
    @State private var colours: [BandsPicture.Colour] = []

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        GeometryReader { geo in
            let total = max(colours.reduce(0) { $0 + $1.share }, 0.0001)
            HStack(spacing: 0) {
                ForEach(colours.indices, id: \.self) { i in
                    Self.colour(colours[i]).frame(width: geo.size.width * colours[i].share / total)
                }
            }
        }
        .background(Color.primary.opacity(0.08))
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 1) }
        .animation(.easeInOut(duration: Motion.fadeDuration), value: colours.count)
        .task(id: entry?.id) {
            guard let entry else { colours = []; return }
            colours = await BackgroundPicks.shared.colours(entry) ?? []
        }
    }

    /// Pushed out from its grey as the background does (1.2×).
    private static func colour(_ c: BandsPicture.Colour) -> Color {
        let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        func out(_ v: Double) -> Double { min(1, max(0, y + (v - y) * 1.2)) }
        return Color(red: out(c.r), green: out(c.g), blue: out(c.b))
    }
}
