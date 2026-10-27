import SwiftUI

/// Settings → Appearance: one list, no sections — switches, Background and Card outlines' choices.
struct AppearanceSettingsDetail: View {
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @AppStorage(AppBackground.followsTitleKey) private var followsTitle = false
    @AppStorage(FixedFocusRing.outlinesKey) private var outlines = FixedFocusRing.outlines.rawValue

    var body: some View {
        SettingsPage(title: SettingsCategory.appearance.title, subtitle: SettingsCategory.appearance.subtitle) {
            SettingsSection {
                SettingsOptionsRow(
                    title: "Background",
                    description: "Dynamic: Home takes on the colours of the title in focus, and its folders follow.",
                    options: [SettingsOption(id: "static", label: "Static"),
                              SettingsOption(id: "dynamic", label: "Dynamic")],
                    selection: followsTitle ? "dynamic" : "static"
                ) { followsTitle = $0 == "dynamic" }
                SettingsOptionsRow(
                    title: "Card outlines",
                    pageDescription: "A thin edge around every card, and a bright one on the card in focus.",
                    options: FixedFocusRing.Outlines.allCases.map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: outlines
                ) { FixedFocusRing.outlines = FixedFocusRing.Outlines(rawValue: $0) ?? .high }
                SettingsToggleRow(
                    title: "Auto-hide top bar",
                    isOn: $settings.autoHideSidebar
                )
            }
        }
    }
}
