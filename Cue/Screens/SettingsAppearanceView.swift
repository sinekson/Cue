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
                    description: "High: thin edges, a bright one in focus. Low: thin edges only.",
                    options: FixedFocusRing.Outlines.allCases.map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: outlines
                ) { FixedFocusRing.outlines = FixedFocusRing.Outlines(rawValue: $0) ?? .high }
                SettingsToggleRow(
                    title: "Hide the top bar",
                    description: "Out of sight until you press Up at the top of a page, or Back.",
                    isOn: $settings.autoHideSidebar
                )
            }
        }
    }
}
