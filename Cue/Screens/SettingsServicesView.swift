import SwiftUI

// MARK: - Services (Settings → Accounts → TMDB, MDBList)

/// A service's key: what it's for, where to get one, how to check and store it.
enum ServiceKey {
    case tmdb, mdblist

    var name: String { self == .tmdb ? "TMDB" : "MDBList" }

    var about: String {
        switch self {
        case .tmdb:
            return "Picks for the billboard, a series' status and seasons, episode details, and TMDB collections. "
                + "Keys are free: sign in at themoviedb.org, open Settings → API and copy the API Key (v3 auth)."
        case .mdblist:
            return "Ratings from IMDb, Rotten Tomatoes, Letterboxd and more on the billboard and Details. "
                + "Keys are free at mdblist.com/preferences."
        }
    }

    /// The phone page's text (HTML).
    var phoneBlurb: String {
        switch self {
        case .tmdb:
            return "Open <a href=\"https://www.themoviedb.org/settings/api\" target=\"_blank\" "
                + "rel=\"noopener\">themoviedb.org/settings/api</a>, copy your "
                + "<strong>API Key (v3 auth)</strong>, and paste it below."
        case .mdblist:
            return "Open <a href=\"https://mdblist.com/preferences\" target=\"_blank\" "
                + "rel=\"noopener\">mdblist.com/preferences</a>, copy your "
                + "<strong>API key</strong>, and paste it below."
        }
    }

    func validate(_ key: String) async -> Bool {
        switch self {
        case .tmdb: return await TMDBService.validate(apiKey: key)
        case .mdblist: return await MDBListService.validate(apiKey: key)
        }
    }
}

/// Settings → TMDB: its key. A key means on — there are no other switches.
struct TMDBServicePage: View {
    @EnvironmentObject private var tmdb: TMDBSettingsStore

    var body: some View {
        SettingsPage(place: SettingsCategory.tmdb.place, subtitle: ServiceKey.tmdb.about) {
            SettingsSection(title: "API key") {
                ServiceKeyRows(service: .tmdb, hasKey: tmdb.hasAPIKey,
                               current: tmdb.settings.trimmedAPIKey) { tmdb.setAPIKey($0) }
            }
        }
    }
}

/// Settings → MDBList: its key, and which ratings show in which order.
struct MDBListServicePage: View {
    @EnvironmentObject private var mdblist: MDBListSettingsStore

    var body: some View {
        let settings = mdblist.settings
        SettingsPage(place: SettingsCategory.mdblist.place, subtitle: ServiceKey.mdblist.about) {
            SettingsSection(title: "API key") {
                ServiceKeyRows(service: .mdblist, hasKey: settings.isConfigured,
                               current: settings.apiKey) { key in
                    mdblist.settings.apiKey = key
                    // Kept true for older Cue versions, which still read it.
                    mdblist.settings.enabled = !key.isEmpty
                }
            }
            SettingsSection(title: "Ratings") {
                let shown = settings.shownProviders
                SettingsLinkRow(
                    title: "Rating priority",
                    description: RatingPriority.about,
                    value: shown.isEmpty ? "None" : shown.prefix(3).map(\.label).joined(separator: ", ")
                        + (shown.count > 3 ? " +\(shown.count - 3)" : "")
                ) { RatingSourcesPage() }
            }
        }
    }
}

/// A service's key rows: send it from your phone, type it, remove it.
private struct ServiceKeyRows: View {
    let service: ServiceKey
    let hasKey: Bool
    let current: String
    let save: (String) -> Void

    @State private var sending = false
    @State private var keyboard: KeyboardRequest?
    @State private var checking = false
    @State private var failed = false
    @State private var confirmRemove = false

    var body: some View {
        SettingsButtonRow(
            title: "Send the key from your phone",
            description: "Shows a QR code: open it on your phone and paste the key there. "
                + "Both have to be on the same network.",
            icon: "qrcode"
        ) { sending = true }
        .fullScreenCover(isPresented: $sending) {
            KeyHandoffPage(service: service, save: save) { sending = false }
        }

        SettingsButtonRow(
            title: "Type the key",
            description: failed ? "That key didn't work. Check you copied all of it, and that you're online."
                                : "Opens the keyboard. The key is checked before it's saved.",
            value: checking ? "Checking…" : (failed ? "Didn't work" : nil),
            icon: "keyboard"
        ) {
            keyboard = KeyboardRequest(text: current, placeholder: "\(service.name) API key") { text in
                check(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))

        if hasKey {
            SettingsButtonRow(
                title: "Remove the key",
                description: "\(service.name) stops working on this TV until you add a key again.",
                icon: "trash"
            ) { confirmRemove = true }
            .alert("Remove the \(service.name) key?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { save("") }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func check(_ key: String) {
        guard !key.isEmpty, key != current else { return }
        checking = true
        failed = false
        Task {
            let valid = await service.validate(key)
            checking = false
            if valid { save(key) } else { failed = true }
        }
    }
}

/// MDBList → Rating priority: three ratings show (on the
/// billboard and Details alike) — the first three a title has, in this
/// order; the rest step in when one is missing. Each source with Move and a
/// switch (off: never shown).
private struct RatingSourcesPage: View {
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @State private var moving: MDBListProvider?

    var body: some View {
        let providers = mdblist.settings.orderedProviders
        // Where the fallbacks start: after the third source that's on.
        let shownIDs = mdblist.settings.shownProviders.map(\.id)
        let fallbackStart = shownIDs.count > FixedFocusBillboardText.ratingsShown
            ? shownIDs[FixedFocusBillboardText.ratingsShown] : nil
        SettingsManagePage(title: "Rating priority", subtitle: RatingPriority.about) {
            ForEach(providers) { provider in
                let shown = mdblist.settings.isShown(provider)
                if provider == providers.first { groupLabel("Shown first") }
                if provider.id == fallbackStart { groupLabel("Fallback") }
                SettingsEntryRow(
                    title: provider.fullName,
                    scrollID: provider.id,
                    dimmed: !shown,
                    actions: [SettingsEntryAction(id: "move", icon: "arrow.up.arrow.down", title: "Move") {
                        moving = provider
                    }],
                    toggle: SettingsEntrySwitch(isOn: shown, title: shown ? "Never show" : "Show") {
                        mdblist.settings.setShown(provider, !shown)
                    },
                    isMoving: moving == provider,
                    anyMoving: moving != nil,
                    onMoveStep: { mdblist.settings.move(provider, by: $0) },
                    onDrop: { moving = nil }
                )
            }
        }
        .onChange(of: moving) { _, provider in TopBarLock.shared.locked = provider != nil }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: SectionHint.size, weight: SectionHint.weight))
            .tracking(SectionHint.tracking)
            .foregroundStyle(SettingsMetrics.secondaryText)
            .padding(.horizontal, 24)
            .padding(.top, 12)
    }
}

enum RatingPriority {
    static let about = "Three ratings show, in this order. If a title doesn't have one, the next one takes its place."
}

/// Scan-to-enter for a key: this Apple TV serves a one-field page on the
/// local network and shows its address as a QR. Neither service has a
/// device login, so the hand-off happens between the phone and the TV.
private struct KeyHandoffPage: View {
    @EnvironmentObject private var theme: ThemeManager
    let service: ServiceKey
    let save: (String) -> Void
    let onDone: () -> Void

    @StateObject private var server: KeyHandoffServer

    init(service: ServiceKey, save: @escaping (String) -> Void, onDone: @escaping () -> Void) {
        self.service = service
        self.save = save
        self.onDone = onDone
        _server = StateObject(wrappedValue: KeyHandoffServer(
            title: "\(service.name) API key", blurb: service.phoneBlurb,
            placeholder: "Paste your \(service.name) API key"))
    }

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: CueSpacing.lg) {
                Text("Send your \(service.name) key")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                if server.accepted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 90))
                        .foregroundStyle(CuePrimitives.success)
                    Text("Key saved.")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                } else if let address = server.address {
                    Text("Scan with your phone, or open \(address) in its browser. Both devices have to be on the same network.")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                    QRCodeView(string: address, side: 360)
                    Text(address)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.palette.secondary)
                } else if let error = server.lastError {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(CuePrimitives.error)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    CueLoadingView(label: "Starting")
                        .frame(height: 360)
                }

                Button(server.accepted ? "Done" : "Cancel", action: onDone)
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, CueSpacing.sm)
            }
            .padding(CueSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            server.onSubmit = { [service, save] value in
                // Checked before saving, like typing it on the TV — a typo
                // says so on the phone, where it can be fixed.
                guard await service.validate(value) else {
                    return (false, "That key didn't work. Check you copied all of it.")
                }
                save(value)
                return (true, "Saved — you can put your phone down.")
            }
            server.start()
        }
        .onDisappear { server.stop() }
        .onExitCommand(perform: onDone)
    }
}

/// A small curated ISO-639-1 language list for TMDB's language.
enum TMDBLanguages {
    static let options = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "hi", "ru", "ar"]

    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}
