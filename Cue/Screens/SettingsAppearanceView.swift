import SwiftUI

/// Settings → Appearance: one list, no sections — Background's page and choices.
struct AppearanceSettingsDetail: View {
    @AppStorage(FixedFocusRing.outlinesKey) private var outlines = FixedFocusRing.outlines.rawValue
    @AppStorage(SourceCardStyle.key) private var sourceCards = SourceCardStyle.current.rawValue
    @AppStorage(DetailOpening.key) private var detailOpening = DetailOpening.current.rawValue
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
                    title: "Opening Details",
                    pageDescription: "Choose how a title opens. Grow opens the card you pressed into the title's "
                        + "page. Fade brings the page's picture in where it stays, a little calmer.",
                    options: DetailOpening.allCases.map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: detailOpening
                ) { detailOpening = $0 }
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

/// The background: the title up, and another now. A title's own is
/// chosen from its card's menu ("Use as Background").
private struct BackgroundPage: View {
    @ObservedObject private var background = BackgroundStore.shared

    var body: some View {
        SettingsPage(title: "Background",
                     subtitle: "The colours of a title on Home, in a layout of their own, a new title every few hours. "
                        + "To use a title's own, hold its card and choose Use as Background; "
                        + "it stays until the next change.") {
            SettingsSection {
                SettingsButtonRow(title: "Pick Another",
                                  description: "Another title from Home.") {
                    background.another()
                }
            }
            SettingsSection(title: "Now") {
                VStack(spacing: 0) {
                    SettingsInfoRow(title: background.shown?.name ?? "Grey", value: reason)
                }
            }
        }
    }

    private var reason: String {
        guard background.shown != nil else { return "Until a title is picked" }
        return background.chosen ? "Chosen by you" : "From Home"
    }
}
