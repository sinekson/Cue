import SwiftUI

/// The Settings screen: a `SettingsPage` — the categories as rows, the
/// focused one described on the left — pushing each category's page.
struct ATVSettingsView: View {

    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore

    /// Categories under General (the accounts have their own section up
    /// top, Developer its own at the bottom).
    private var generalCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter { !SettingsCategory.accounts.contains($0) && $0 != .developer }
    }

    /// Categories already on the new two-pane pages (`SettingsPage`); the
    /// rest still get the old pane's frame and padding.
    private static let twoPane: Set<SettingsCategory> = [.appearance, .account, .tmdb, .mdblist, .homeContent]

    var body: some View {
        SettingsPage(place: SettingsPlace(icon: "gearshape.fill", name: nil),
                     subtitle: "Cue's preferences, by topic.") {
            SettingsSection(title: "Accounts") {
                ForEach(SettingsCategory.accounts) { categoryRow($0, value: state(of: $0)) }
            }
            SettingsSection(title: "General") {
                ForEach(generalCategories) { categoryRow($0) }
            }
            SettingsSection(title: "Developer") {
                categoryRow(.developer)
            }
        }
        .navigationDestination(for: SettingsCategory.self) { category in
            if Self.twoPane.contains(category) {
                SettingsCategoryPane(category: category)
            } else {
                pane(SettingsCategoryPane(category: category))
            }
        }
        .navigationDestination(for: PlaybackSection.self) { pane(PlaybackSettingsDetail(section: $0)) }
    }

    /// An account's state, on its row.
    private func state(of category: SettingsCategory) -> String? {
        switch category {
        case .account:
            guard case .signedIn(_, let email) = account.authState else { return "Signed out" }
            return email.isEmpty ? "Signed in" : email
        case .tmdb: return tmdb.hasAPIKey ? "Connected" : "Add key"
        case .mdblist: return mdblist.settings.isConfigured ? "Connected" : "Add key"
        default: return nil
        }
    }

    private func categoryRow(_ category: SettingsCategory, value: String? = nil) -> some View {
        NavigationLink(value: category) {
            SettingsRowLabel(title: category.title, value: value, chevron: true,
                             info: SettingsInfo(title: category.title, description: category.subtitle,
                                                icon: category.icon, tint: category.tint))
        }
        .buttonStyle(SettingsRowStyle())
    }

    /// Pushed detail pages not yet on `SettingsPage`: the old pane's frame.
    private func pane(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, CueSpacing.huge)
            .background(ATVBackground())
    }
}
