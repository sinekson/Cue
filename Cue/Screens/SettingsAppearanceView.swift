import SwiftUI

/// Settings → Appearance: whether the background follows the title, the
/// billboard and the top bar.
struct AppearanceSettingsDetail: View {
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @AppStorage(AppBackground.followsTitleKey) private var followsTitle = false
    @AppStorage(BillboardAutoPage.key) private var billboardAutoPage = true
    @AppStorage(FixedFocusRing.edgeKey) private var focusEdge = true

    var body: some View {
        SettingsPage(place: SettingsCategory.appearance.place, subtitle: SettingsCategory.appearance.subtitle) {
            SettingsSection(title: "Look") {
                SettingsToggleRow(
                    title: "Background follows the title",
                    description: "Home, Movies and Series take on the colours of the title in focus, a collection's panel too; a folder keeps its cover's. A genre, person or studio opened from a title's page shows that title's picture, blurred. Off: the same calm background everywhere.",
                    isOn: $followsTitle
                )
                SettingsToggleRow(
                    title: "Focus edge",
                    description: "A bright line around the card in focus, on top of its shadow and lift — easier to spot from across the room. Off: the shadow and the lift alone.",
                    isOn: $focusEdge
                )
                .onChange(of: focusEdge) { _, _ in FixedFocusRing.refreshAll() }
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
