import SwiftUI

/// Settings → Appearance: one list, no sections — Background's page and choices.
struct AppearanceSettingsDetail: View {
    @AppStorage(FixedFocusRing.outlinesKey) private var outlines = FixedFocusRing.outlines.rawValue
    @AppStorage(SourceCardStyle.key) private var sourceCards = SourceCardStyle.current.rawValue
    @ObservedObject private var background = BackgroundStore.shared

    var body: some View {
        SettingsPage(title: SettingsCategory.appearance.title) {
            SettingsSection {
                SettingsLinkRow(title: "Background", value: background.shown?.name ?? "Grey") {
                    BackgroundPage()
                }
                SettingsOptionsRow(
                    title: "Card Outlines",
                    pageDescription: "Choose how cards are framed. Edges and Focus draws a thin edge around every "
                        + "card and a bright one on the card in focus. Edges Only keeps the thin edge. "
                        + "Off draws neither.",
                    options: FixedFocusRing.Outlines.allCases.map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: outlines
                ) { FixedFocusRing.outlines = FixedFocusRing.Outlines(rawValue: $0) ?? .high }
                SettingsOptionsRow(
                    title: "Source Cards",
                    pageDescription: "Choose how links read when you pick a source. Styled makes a tidy card from "
                        + "the file name, with the add-on's score. Raw shows the add-on's own text, as it sends it.",
                    options: SourceCardStyle.allCases.map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: sourceCards
                ) { sourceCards = $0 }
            }
        }
    }
}

/// The background: what a launch brings, another now, saving the one up;
/// the saved ones (up to 12), each its page: Use Now, Remove from Saved.
/// A title's own is chosen from its card's menu ("Use as Background",
/// then "Save Background").
struct BackgroundPage: View {
    @EnvironmentObject private var nav: SettingsNav
    @ObservedObject private var background = BackgroundStore.shared
    @AppStorage(BackgroundPicks.AtLaunch.key) private var atLaunch = BackgroundPicks.AtLaunch.home.rawValue

    var body: some View {
        SettingsPage(title: "Background",
                     subtitle: "The colours of a title, in a layout of their own. To use a title's own, hold its "
                        + "card and choose Use as Background; hold it again to save it.") {
            SettingsSection {
                SettingsOptionsRow(
                    title: "Change at Launch",
                    pageDescription: "From Home takes a title on Home at random. From Saved takes one of your "
                        + "saved backgrounds. Never keeps the one up.",
                    options: BackgroundPicks.AtLaunch.allCases
                        .filter { $0 != .saved || !background.saved.isEmpty }
                        .map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: atLaunch
                ) { atLaunch = $0 }
                SettingsButtonRow(title: "Pick Another",
                                  description: atLaunch == BackgroundPicks.AtLaunch.saved.rawValue
                                    ? "Another of your saved backgrounds." : "Another title from Home.") {
                    background.another()
                }
                if let shown = background.shown {
                    let isSaved = background.isSaved(shown.id)
                    // One name, "Saved" beside it (a changing name lost focus).
                    SettingsButtonRow(title: "Save This Background",
                                      description: isSaved ? "Select again to take it off Saved."
                                        : "\(background.saved.count) of \(BackgroundPicks.savedLimit) saved.",
                                      value: isSaved ? "Saved" : nil) {
                        background.toggleSaved()
                    }
                }
            }
            if !background.saved.isEmpty {
                SettingsSection(title: "Saved") {
                    ForEach(background.saved, id: \.id) { entry in
                        Button { nav.push(SavedBackgroundPage(id: entry.id)) } label: {
                            SettingsRowLabel(title: entry.name,
                                             value: background.shown?.id == entry.id ? "Now" : nil,
                                             chevron: true,
                                             leading: AnyView(BackgroundPreview(entry: entry)))
                        }
                        .settingsRow(id: "saved-" + entry.id)
                    }
                }
            }
            SettingsSection(title: "Now") {
                SettingsInfoRows {
                    SettingsInfoRow(title: background.shown?.name ?? "Grey", value: reason)
                }
            }
        }
    }

    private var reason: String {
        guard background.shown != nil else { return "Until a title is picked" }
        switch background.source {
        case .home: return "From Home"
        case .saved: return "From Saved"
        case .chosen: return "Chosen by you"
        }
    }
}

/// A saved background: Use Now (unless it's up), Remove from Saved.
private struct SavedBackgroundPage: View {
    @EnvironmentObject private var nav: SettingsNav
    @ObservedObject private var background = BackgroundStore.shared
    let id: String

    var body: some View {
        if let entry = background.saved.first(where: { $0.id == id }) {
            SettingsPage(title: entry.name) {
                SettingsSection {
                    if background.shown?.id != entry.id {
                        SettingsButtonRow(title: "Use Now") { background.set(entry) }
                    }
                    SettingsButtonRow(title: "Remove from Saved") {
                        nav.back()
                        background.unsave(entry.id)
                    }
                }
            }
        }
    }
}

/// A saved background drawn small, in the row's height, in tvOS's mode.
private struct BackgroundPreview: View {
    let entry: BackgroundPicks.Entry
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            shape.fill(Color.primary.opacity(0.08))
            if let image {
                Image(uiImage: image).resizable().transition(.opacity)
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(shape)
        .animation(.easeInOut(duration: Motion.fadeDuration), value: image)
        .task(id: "\(entry.id)-\(scheme)") {
            image = await BackgroundPicks.shared.preview(entry)
        }
    }
}

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
