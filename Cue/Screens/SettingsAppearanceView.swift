import SwiftUI

/// Settings → Appearance: the app's background colour, whether Home follows
/// the focused title's colours, and the top bar.
struct AppearanceSettingsDetail: View {
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @AppStorage(AppBackground.storageKey) private var background: AppBackground = .slate
    @AppStorage(AppBackground.homeFollowsTitleKey) private var homeFollowsTitle = true
    @AppStorage(BillboardAutoPage.key) private var billboardAutoPage = true

    var body: some View {
        SettingsPage(place: SettingsCategory.appearance.place, subtitle: SettingsCategory.appearance.subtitle) {
            SettingsSection(title: "Look") {
                SettingsChoiceRow(
                    title: "Background",
                    description: "Behind Settings, Search and Library — and behind Home, unless it follows the title.",
                    options: AppBackground.allCases.map {
                        SettingsOption(id: $0.rawValue, label: $0.displayName)
                    },
                    selection: background.rawValue,
                    // The focused colour fills the screen while choosing.
                    onFocusOption: { AppBackgroundPreview.shared.choice = $0.flatMap(AppBackground.init) }
                ) { background = AppBackground(rawValue: $0) ?? .slate }

                SettingsToggleRow(
                    title: "Home follows the title",
                    description: "Below the billboard, Home, Movies and Series take on the focused title's colours. Off: the background.",
                    isOn: $homeFollowsTitle
                )
            }

            SettingsSection(title: "Billboard") {
                SettingsToggleRow(
                    title: "Billboard pages by itself",
                    description: "Resting on the billboard, it moves on to the next title every \(Int(BillboardAutoPage.interval)) seconds, up to the last one — the bar under it fills as it goes. Any press starts it over. Off: it changes only when you press Left or Right.",
                    isOn: $billboardAutoPage
                )
            }

            SettingsSection(title: "Navigation") {
                SettingsToggleRow(
                    title: "Hide the top bar",
                    description: "Keep the navigation off screen until you press Up at the top of a page (or Menu); picking a tab hides it again. Settings always keeps it.",
                    isOn: $settings.autoHideSidebar
                )
            }
        }
    }
}
