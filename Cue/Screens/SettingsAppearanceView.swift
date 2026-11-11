import SwiftUI

/// Settings → Appearance: one list, no sections — Background's page and choices.
struct AppearanceSettingsDetail: View {
    @AppStorage(FixedFocusRing.outlinesKey) private var outlines = FixedFocusRing.outlines.rawValue
    @AppStorage(SourceCardStyle.key) private var sourceCards = SourceCardStyle.current.rawValue
    @ObservedObject private var background = BackgroundStore.shared

    var body: some View {
        SettingsPage(title: SettingsCategory.appearance.title) {
            SettingsSection {
                SettingsLinkRow(title: "Background", value: background.shown?.name ?? "Bands") {
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

/// The background: what's up and why, and another now. A title's own is
/// chosen from its card's menu ("Use as Background").
private struct BackgroundPage: View {
    @ObservedObject private var background = BackgroundStore.shared

    var body: some View {
        SettingsPage(title: "Background",
                     subtitle: "A picture from a title on Home, changing with the time of day: lighter by day, "
                        + "darkest at night. To use a title's own, hold its card and choose Use as Background; "
                        + "it stays until the next change.") {
            SettingsSection {
                SettingsButtonRow(title: "Pick Another",
                                  description: "Another picture for this time of day.") {
                    background.another()
                }
            }
            SettingsSection(title: "Now") {
                VStack(spacing: 0) {
                    SettingsInfoRow(title: background.shown?.name ?? "Bands", value: reason)
                }
            }
        }
    }

    private var reason: String {
        guard background.shown != nil else { return "Until titles are picked" }
        return background.chosen ? "Chosen by you" : BackgroundPicks.TimeOfDay.now.name
    }
}
