import SwiftUI

// MARK: - Services (Settings → Accounts → TMDB, MDBList)

/// A service's key: what it's for, where to get one, how to check and store it.
enum ServiceKey {
    case tmdb, mdblist

    var name: String { self == .tmdb ? "TMDB" : "MDBList" }

    var about: String {
        switch self {
        case .tmdb:
            return "Powers search and everything Cue shows about a title."
        case .mdblist:
            return "Ratings from IMDb, Rotten Tomatoes, Letterboxd and more."
        }
    }

    /// Where a key comes from.
    var howTo: String {
        switch self {
        case .tmdb: return "Keys are free: sign in at themoviedb.org, open Settings → API and copy the API Key (v3 auth)."
        case .mdblist: return "Keys are free at mdblist.com/preferences."
        }
    }

    /// The phone page's server (`KeyHandoffServer`), saving what's sent once
    /// it's checked — as typing it on the TV; a typo says so on the phone,
    /// where it can be fixed.
    @MainActor
    func handoffServer() -> KeyHandoffServer {
        KeyHandoffServer(title: "\(name) API key", blurb: phoneBlurb, placeholder: "Paste your \(name) API key")
    }

    @MainActor
    func serve(_ server: KeyHandoffServer, save: @escaping (String) -> Void) {
        server.onSubmit = { value in
            guard await validate(value) else {
                return (false, "That key didn't work. Check you copied all of it.")
            }
            save(value)
            return (true, "Saved — you can put your phone down.")
        }
        server.start()
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
        await check(key) == true
    }

    /// Whether the service takes the key; nil when it couldn't be reached.
    func check(_ key: String) async -> Bool? {
        switch self {
        case .tmdb: return await TMDBService.check(apiKey: key)
        case .mdblist: return await MDBListService.check(apiKey: key)
        }
    }
}

/// TMDB's answers kept on disk: how much, of how much, and a way to drop
/// them (the next pages ask TMDB again).
private struct TMDBCacheSection: View {
    @State private var used = TMDBService.cacheUsage

    var body: some View {
        SettingsSection(title: "Cache") {
            SettingsInfoRow(title: "Stored",
                            value: "\(Self.megabytes(used.disk)) of \(Self.megabytes(used.capacity))")
            SettingsButtonRow(title: "Clear Cache") {
                TMDBService.clearCache()
                used = TMDBService.cacheUsage
            }
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// MDBList's account and the day's requests, only to read: what its last
/// answer said (`/user` is asked as the page opens, with the key's check).
private struct MDBListUsageSection: View {
    @ObservedObject var usage: MDBListUsage

    var body: some View {
        if usage.account != nil || usage.snapshot != nil {
            SettingsSection(title: "Usage") {
                if let account = usage.account {
                    SettingsInfoRow(title: "Account",
                                    value: [account.username, account.plan].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                if let snapshot = usage.snapshot {
                    SettingsInfoRow(title: "Requests Today",
                                    value: "\((snapshot.limit - snapshot.remaining).formatted()) of \(snapshot.limit.formatted())")
                    if let resetsAt = snapshot.resetsAt {
                        SettingsInfoRow(title: "Resets", value: Self.when(resetsAt))
                    }
                }
                if let paused = usage.pausedUntil, paused > Date() {
                    SettingsInfoRow(title: "Paused", value: "Too many requests · until \(Self.when(paused))")
                }
            }
        }
    }

    /// "Today at 02:00", "Tomorrow at 02:00".
    private static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }
}

/// Settings → TMDB: the key's row, the language, the cache (its size,
/// Clear Cache), TMDB's attribution at the end. No request counts: TMDB
/// has no quota and reports none.
struct TMDBServicePage: View {
    @EnvironmentObject private var tmdb: TMDBSettingsStore

    var body: some View {
        SettingsPage(title: ServiceKey.tmdb.name, subtitle: ServiceKey.tmdb.about) {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                ServiceKeyRow(service: .tmdb, key: tmdb.settings.trimmedAPIKey) { tmdb.setAPIKey($0) }
                SettingsOptionsRow(
                    title: "Language",
                    options: TMDBLanguages.options.map { SettingsOption(id: $0, label: TMDBLanguages.displayName($0)) },
                    selection: tmdb.settings.language
                ) { tmdb.settings.language = $0 }
            }
            TMDBCacheSection()
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.system(size: 24))
                .foregroundStyle(Color.white.opacity(FixedFocusText.captionDetail))
                .padding(.leading, SettingsMetrics.labelIndent)
        }
    }
}

/// Settings → MDBList: the key's row, then the ratings — where they
/// show, the sources' order (its own page), how many on Home's rows.
struct MDBListServicePage: View {
    @EnvironmentObject private var mdblist: MDBListSettingsStore

    var body: some View {
        SettingsPage(title: ServiceKey.mdblist.name, subtitle: ServiceKey.mdblist.about) {
            ServiceKeyRow(service: .mdblist, key: mdblist.settings.apiKey) { key in
                mdblist.settings.apiKey = key
                // Kept true for older Cue versions, which still read it.
                mdblist.settings.enabled = !key.isEmpty
            }
            if !mdblist.settings.apiKey.isEmpty { MDBListUsageSection(usage: .shared) }
            ratings
        }
    }

    private var ratings: some View {
        SettingsSection(title: "Ratings") {
            SettingsOptionsRow(
                title: "Show ratings",
                options: RatingsPlace.allCases.map { SettingsOption(id: $0.rawValue, label: $0.label) },
                selection: mdblist.settings.place.rawValue
            ) { mdblist.settings.place = RatingsPlace(rawValue: $0) ?? .everywhere }
            SettingsLinkRow(title: "Order",
                            value: mdblist.settings.shownProviders.prefix(FixedFocusBillboardText.ratingsShown)
                                .map(\.label).joined(separator: ", ")) {
                RatingOrderPage()
            }
            // How many of them under Home's fixed box.
            SettingsOptionsRow(
                title: "On Home's rows",
                options: (1...FixedFocusBillboardText.ratingsShown).map {
                    SettingsOption(id: "\($0)", label: $0 == 1 ? "1 rating" : "\($0) ratings")
                },
                selection: "\(mdblist.settings.rowCount)"
            ) { mdblist.settings.rowCount = Int($0) ?? 1 }
        }
    }
}

/// MDBList → Order: the sources, one row each — Move, and a switch.
private struct RatingOrderPage: View {
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @State private var moving: MDBListProvider?

    var body: some View {
        SettingsPage(title: "Order",
                     subtitle: "The first three show on titles; the rest stand in when one is missing.") {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
            ForEach(mdblist.settings.orderedProviders) { provider in
                let shown = mdblist.settings.isShown(provider)
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
        }
        .onChange(of: moving) { _, provider in TopBarLock.shared.locked = provider != nil }
        .onDisappear { TopBarLock.shared.locked = false }
    }
}

extension ServiceKey {
    /// The key's last four, the rest dots: enough to tell keys apart, not
    /// enough to copy off a photo of the screen.
    static func masked(_ key: String) -> String {
        String(repeating: "•", count: 10) + key.suffix(4)
    }
}

/// A service's key as one row: "API Key" and what's there — the key
/// masked, "Not added", or "Not working" (checked as the page opens) —
/// opening its page (`ServiceKeyDetailPage`).
private struct ServiceKeyRow: View {
    @EnvironmentObject private var nav: SettingsNav
    let service: ServiceKey
    let key: String
    let setKey: (String) -> Void
    /// The saved key works: nil until known, and when the service can't be
    /// reached (offline isn't "Not working").
    @State private var works: Bool?

    var body: some View {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Button {
            nav.push(ServiceKeyDetailPage(service: service, key: key, setKey: setKey))
        } label: {
            SettingsRowLabel(title: "API Key",
                             value: key.isEmpty ? "Not added" : works == false ? "Not working" : ServiceKey.masked(key),
                             chevron: true)
        }
        .settingsRow(id: "API Key")
        .task(id: key) {
            works = nil
            guard !key.isEmpty else { return }
            works = await service.check(key)
        }
    }
}

/// A service's key, its own page. With a key: Remove Key (the key on its
/// right, confirmed). Without: Type Key, Send from Phone (the full-screen
/// QR). A key saved or removed, back to the service's page.
private struct ServiceKeyDetailPage: View {
    @EnvironmentObject private var nav: SettingsNav
    let service: ServiceKey
    let key: String
    let setKey: (String) -> Void

    @State private var keyboard: KeyboardRequest?
    @State private var checking = false
    @State private var failed = false
    @State private var sending = false
    @State private var sent = false
    @State private var confirmRemove = false

    private var subtitle: String {
        if checking { return "Checking the key…" }
        if failed { return "That key didn't work. Check you copied all of it." }
        return key.isEmpty ? service.howTo : "Without it, \(service.name) stops working on this TV."
    }

    var body: some View {
        SettingsPage(title: "API Key", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                if key.isEmpty {
                    SettingsButtonRow(title: "Type Key") {
                        keyboard = KeyboardRequest(text: "", placeholder: "\(service.name) API key") { text in
                            check(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                    SettingsButtonRow(title: "Send from Phone") { sending = true }
                } else {
                    SettingsButtonRow(title: "Remove Key", value: ServiceKey.masked(key)) { confirmRemove = true }
                }
            }
            .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        }
        .fullScreenCover(isPresented: $sending) {
            KeyHandoffPage(service: service, save: { setKey($0); sent = true }) {
                sending = false
                if sent { nav.pop() }
            }
        }
        .alert("Remove the \(service.name) key?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { setKey(""); nav.pop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(service.name) stops working on this TV until you add a key again.")
        }
    }

    private func check(_ candidate: String) {
        guard !candidate.isEmpty else { return }
        checking = true
        failed = false
        Task {
            let valid = await service.validate(candidate)
            checking = false
            if valid { setKey(candidate); nav.pop() } else { failed = true }
        }
    }
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
        _server = StateObject(wrappedValue: service.handoffServer())
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
        .onAppear { service.serve(server, save: save) }
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
