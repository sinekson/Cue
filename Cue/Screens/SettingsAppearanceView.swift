import SwiftUI

/// Settings → Appearance: four switches, one list, no sections.
struct AppearanceSettingsDetail: View {
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @AppStorage(AppBackground.followsTitleKey) private var followsTitle = false
    @AppStorage(FixedFocusRing.edgeKey) private var focusEdge = true
    @AppStorage(StageTrailer.peekMovesKey) private var peekMovesOut = false

    var body: some View {
        SettingsPage(title: SettingsCategory.appearance.title, subtitle: SettingsCategory.appearance.subtitle) {
            SettingsSection {
                SettingsToggleRow(
                    title: "Colours from the title",
                    description: "Home, Movies and Series take on the colours of the title in focus.",
                    isOn: $followsTitle
                )
                SettingsToggleRow(
                    title: "Focus outline",
                    description: "A bright edge around the card in focus, easier to spot.",
                    isOn: $focusEdge
                )
                .onChange(of: focusEdge) { _, _ in FixedFocusRing.refreshAll() }
                SettingsToggleRow(
                    title: "Hide the top bar",
                    description: "Out of sight until you press Up at the top of a page, or Back.",
                    isOn: $settings.autoHideSidebar
                )
                SettingsToggleRow(
                    title: "Trailers: move the row out",
                    description: "While a trailer plays, the row below and the page dots move out the bottom instead of fading.",
                    isOn: $peekMovesOut
                )
            }
        }
    }
}
