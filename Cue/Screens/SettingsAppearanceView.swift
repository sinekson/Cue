import SwiftUI

/// Settings → Appearance: one list, no sections — switches, Background and Card outlines' choices.
struct AppearanceSettingsDetail: View {
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @AppStorage(AppBackground.followsTitleKey) private var followsTitle = false
    @AppStorage(FixedFocusRing.outlinesKey) private var outlines = FixedFocusRing.outlines.rawValue

    var body: some View {
        SettingsPage(title: SettingsCategory.appearance.title) {
            SettingsSection {
                SettingsOptionsRow(
                    title: "Background",
                    pageDescription: "Choose what's behind the pages. Static keeps one dark backdrop everywhere. "
                        + "Dynamic takes on the colours of the title in focus on Home, Movies and Series.",
                    options: [SettingsOption(id: "static", label: "Static"),
                              SettingsOption(id: "dynamic", label: "Dynamic")],
                    selection: followsTitle ? "dynamic" : "static"
                ) { followsTitle = $0 == "dynamic" }
                SettingsOptionsRow(
                    title: "Card Outlines",
                    pageDescription: "Choose how cards are framed. Edges and Focus draws a thin edge around every "
                        + "card and a bright one on the card in focus. Edges Only keeps the thin edge. "
                        + "Off draws neither.",
                    options: FixedFocusRing.Outlines.allCases.map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: outlines
                ) { FixedFocusRing.outlines = FixedFocusRing.Outlines(rawValue: $0) ?? .high }
                SettingsToggleRow(
                    title: "Auto-Hide Top Bar",
                    isOn: $settings.autoHideSidebar
                )
            }
        }
    }
}
