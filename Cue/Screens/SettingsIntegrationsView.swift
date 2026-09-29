import SwiftUI

/// Settings → Integrations: the external services Cue talks to — TMDB
/// and MDBList. The Nuvio account has its own pane.
struct IntegrationsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @State private var sheet: IntegrationSheet?

    enum IntegrationSheet: String, Identifiable { case tmdb, mdblist; var id: String { rawValue } }

    var body: some View {
        // APK layout: a single list of drill-in rows, each opening a sub-screen.
        DetailScaffold(title: SettingsCategory.integration.title, subtitle: SettingsCategory.integration.subtitle) {
            SettingsGroupCard(title: "") {
                // Nuvio account moved to Settings → Account.
                integrationRow(title: "TMDB", subtitle: "Metadata enrichment controls", icon: "film.stack") { sheet = .tmdb }
                integrationRow(title: "MDBList", subtitle: "External ratings providers", icon: "star.circle.fill") { sheet = .mdblist }
            }
        }
        .fullScreenCover(item: $sheet) { s in
            ZStack {
                ATVBackground()
                integrationSheet(s)
            }
            .environmentObject(theme)
            .environmentObject(tmdb)
            .environmentObject(mdblist)
            .onExitCommand { sheet = nil }
        }
    }

    private func integrationRow(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsValueCard(title: title, subtitle: subtitle, value: "", icon: icon)
        }
        .buttonStyle(PlainCardButtonStyle())
    }

    @ViewBuilder
    private func integrationSheet(_ s: IntegrationSheet) -> some View {
        switch s {
        case .tmdb:
            DetailScaffold(title: "TMDB", subtitle: "Metadata enrichment controls") {
                SettingsGroupCard(title: "") { tmdbSection }
            }
        case .mdblist:
            DetailScaffold(title: "MDBList", subtitle: "External ratings providers") {
                SettingsGroupCard(title: "") { mdblistSection }
            }
        }
    }

    // MARK: - MDBList

    private var mdblistSection: some View {
        VStack(alignment: .leading, spacing: CueSpacing.md) {
            SettingsToggleCard(
                title: "Enable MDBList ratings",
                subtitle: "Aggregate scores across rating sources",
                isOn: Binding(get: { mdblist.settings.enabled }, set: { mdblist.settings.enabled = $0 })
            )

            if mdblist.settings.enabled {
                MDBListKeyRow()
                ForEach(MDBListProvider.allCases) { provider in
                    MDBListProviderToggle(provider: provider)
                }
            }

            Text("Get a key at mdblist.com/preferences.")
                .font(.system(size: 18))
                .foregroundStyle(theme.palette.textTertiary)
                .padding(.top, 2)
        }
    }

    // MARK: - TMDB

    private var tmdbSection: some View {
        VStack(alignment: .leading, spacing: CueSpacing.md) {
            // ABOVE the switch, and always visible: the key is the thing that
            // turns TMDB on. Hiding it behind the switch meant the one control
            // that matters was the one you couldn't reach.
            TMDBKeyRow()

            SettingsToggleCard(
                title: "Enable TMDB",
                subtitle: tmdb.hasAPIKey
                    ? "Powers TMDB sources in every collection (lists, collections, companies, networks, discover)"
                    : "Add your API key above to switch this on",
                isOn: Binding(get: { tmdb.settings.enabled },
                              set: { tmdb.settings.enabled = $0 && tmdb.hasAPIKey })
            )

            if tmdb.settings.enabled {
                SettingsToggleCard(
                    title: "Enrich Continue Watching",
                    subtitle: "Fetch missing titles and artwork for Continue Watching rows synced from other devices. Off skips those lookups.",
                    isOn: Binding(get: { tmdb.settings.enrichContinueWatching }, set: { tmdb.settings.enrichContinueWatching = $0 })
                )

                CueDropdown(
                    title: "Language",
                    subtitle: "TMDB metadata language",
                    selection: tmdb.settings.language,
                    options: TMDBLanguages.options.map { CueDropdownOption($0, TMDBLanguages.displayName($0)) }
                ) { tmdb.settings.language = $0 }

                SettingsToggleCard(
                    title: "Cast & Crew",
                    subtitle: "Show TMDB cast, crew, and director on the details page.",
                    isOn: Binding(get: { tmdb.settings.useCredits }, set: { tmdb.settings.useCredits = $0 })
                )
                SettingsToggleCard(
                    title: "Trailers",
                    subtitle: "Show TMDB trailers and the auto-playing hero trailer on details.",
                    isOn: Binding(get: { tmdb.settings.useTrailers }, set: { tmdb.settings.useTrailers = $0 })
                )
                SettingsToggleCard(
                    title: "More Like This",
                    subtitle: "Show the TMDB recommendations row on the details page.",
                    isOn: Binding(get: { tmdb.settings.useMoreLikeThis }, set: { tmdb.settings.useMoreLikeThis = $0 })
                )
                SettingsToggleCard(
                    title: "Details",
                    subtitle: "Show TMDB country and spoken-language details.",
                    isOn: Binding(get: { tmdb.settings.useDetails }, set: { tmdb.settings.useDetails = $0 })
                )
                SettingsToggleCard(
                    title: "Release dates",
                    subtitle: "Show the TMDB release date on the details page.",
                    isOn: Binding(get: { tmdb.settings.useReleaseDates }, set: { tmdb.settings.useReleaseDates = $0 })
                )
                SettingsToggleCard(
                    title: "Production companies",
                    subtitle: "Show the TMDB production-companies row.",
                    isOn: Binding(get: { tmdb.settings.useProductions }, set: { tmdb.settings.useProductions = $0 })
                )
                SettingsToggleCard(
                    title: "Collections",
                    subtitle: "Show the “part of a collection” row and its other entries.",
                    isOn: Binding(get: { tmdb.settings.useCollections }, set: { tmdb.settings.useCollections = $0 })
                )
                SettingsToggleCard(
                    title: "Episodes",
                    subtitle: "Fetch per-episode TMDB ratings and air dates for series.",
                    isOn: Binding(get: { tmdb.settings.useEpisodes }, set: { tmdb.settings.useEpisodes = $0 })
                )
            }

            Text("TMDB keys are free and personal: sign in at themoviedb.org, open Settings → API, and copy the API Key (v3 auth).")
                .font(.system(size: 18))
                .foregroundStyle(theme.palette.textTertiary)
                .padding(.top, 2)
        }
    }

}

// MARK: - MDBList rows

/// TMDB API key row — the same shape as the MDBList key row.
private struct TMDBKeyRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @State private var showEditor = false

    var body: some View {
        Button { showEditor = true } label: {
            HStack(spacing: CueSpacing.lg) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("API Key")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(tmdb.hasAPIKey
                         ? "Connected · key set"
                         : "Scan a QR to send your key from your phone, or paste it here")
                        .font(.system(size: 19))
                        .foregroundStyle(tmdb.hasAPIKey ? CuePrimitives.success : theme.palette.textSecondary)
                }
                Spacer()
                Image(systemName: tmdb.hasAPIKey ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(tmdb.hasAPIKey ? CuePrimitives.success : theme.palette.textTertiary)
            }
            .integrationRowBackground(theme)
        }
        .buttonStyle(PlainCardButtonStyle())
        .fullScreenCover(isPresented: $showEditor) {
            TMDBKeyEditor { showEditor = false }
                .environmentObject(theme)
                .environmentObject(tmdb)
        }
    }
}

private struct TMDBKeyEditor: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    let onDone: () -> Void

    @State private var key = ""
    @State private var validating = false
    @State private var status: String?
    @State private var showQR = false

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: CueSpacing.xl) {
                Text("TMDB API Key")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Sign in at themoviedb.org → Settings → API and copy your API Key (v3 auth). It's free.")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                    .fixedSize(horizontal: false, vertical: true)

                // The key already lives in a browser tab on the phone. Scanning
                // beats retyping 32 hex characters on a remote.
                Button { showQR = true } label: {
                    HStack(spacing: CueSpacing.sm) {
                        Image(systemName: "qrcode")
                        Text("Send from my phone")
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.palette.onSecondary)
                    .padding(.horizontal, CueSpacing.xl)
                    .padding(.vertical, CueSpacing.md)
                    .background(Capsule().fill(theme.palette.secondary))
                }
                .buttonStyle(PlainCardButtonStyle())

                Text("or type it here")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textTertiary)

                SecureField("Paste API key", text: $key)
                    .font(.system(size: 24))
                    .frame(maxWidth: 760)

                if let status {
                    Text(status)
                        .font(.system(size: 20))
                        .foregroundStyle(status.hasPrefix("Valid") ? CuePrimitives.success : CuePrimitives.error)
                }

                HStack(spacing: CueSpacing.lg) {
                    Button(action: verifyAndSave) {
                        if validating { ProgressView().tint(theme.palette.onSecondary) }
                        else { Text("Verify & Save") }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if tmdb.hasAPIKey {
                        Button("Remove", role: .destructive) {
                            tmdb.setAPIKey("")
                            onDone()
                        }
                    }
                    Button("Cancel", role: .cancel, action: onDone)
                }
                .font(.system(size: 24, weight: .semibold))
            }
            .padding(CueSpacing.huge)
        }
        .onAppear { key = tmdb.settings.trimmedAPIKey }
        // Same as Cancel — dismiss without saving.
        .onExitCommand { onDone() }
        .fullScreenCover(isPresented: $showQR) {
            TMDBKeyHandoffPage { saved in
                showQR = false
                if saved { onDone() }
            }
            .environmentObject(theme)
            .environmentObject(tmdb)
        }
    }

    private func verifyAndSave() {
        guard !validating else { return }
        validating = true
        status = nil
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        Task {
            let valid = await TMDBService.validate(apiKey: trimmed)
            validating = false
            if valid {
                tmdb.setAPIKey(trimmed)
                status = "Valid — saved."
                onDone()
            } else {
                status = "Invalid key or network error."
            }
        }
    }
}

/// Scan-to-enter for the TMDB key: this Apple TV serves a one-field page on the
/// local network and shows its address as a QR. TMDB itself has no device/QR
/// login — every v3 request is authenticated by the key, so there is no flow
/// that hands one out — hence the hand-off happens between the phone and the
/// TV rather than through TMDB.
private struct TMDBKeyHandoffPage: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    /// `true` when a key was accepted and saved.
    let onDone: (Bool) -> Void

    @StateObject private var server = KeyHandoffServer(
        title: "TMDB API key",
        blurb: "Open <a href=\"https://www.themoviedb.org/settings/api\" target=\"_blank\" "
             + "rel=\"noopener\">themoviedb.org/settings/api</a>, copy your "
             + "<strong>API Key (v3 auth)</strong>, and paste it below.",
        placeholder: "Paste your TMDB API key"
    )

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: CueSpacing.lg) {
                Text("Send your TMDB key")
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

                Button(server.accepted ? "Done" : "Cancel") { onDone(server.accepted) }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, CueSpacing.sm)
            }
            .padding(CueSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            server.onSubmit = { value in
                // Verified before saving, exactly like on-TV entry — a typo
                // should say so on the phone, where it can be fixed, rather
                // than quietly emptying every TMDB-backed row.
                guard await TMDBService.validate(apiKey: value) else {
                    return (false, "That key didn't work. Check you copied the v3 API key.")
                }
                tmdb.setAPIKey(value)
                return (true, "Saved — you can put your phone down.")
            }
            server.start()
        }
        .onDisappear { server.stop() }
        .onExitCommand { onDone(server.accepted) }
    }
}

private struct MDBListKeyRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @State private var showEditor = false

    private var isConfigured: Bool {
        !mdblist.settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Button { showEditor = true } label: {
            HStack(spacing: CueSpacing.lg) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("API Key")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(isConfigured ? "Connected · key set" : "Tap to paste your MDBList key")
                        .font(.system(size: 19))
                        .foregroundStyle(isConfigured ? CuePrimitives.success : theme.palette.textSecondary)
                }
                Spacer()
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(isConfigured ? CuePrimitives.success : theme.palette.textTertiary)
            }
            .integrationRowBackground(theme)
        }
        .buttonStyle(PlainCardButtonStyle())
        .fullScreenCover(isPresented: $showEditor) {
            MDBListKeyEditor { showEditor = false }
                .environmentObject(theme)
                .environmentObject(mdblist)
        }
    }
}

private struct MDBListProviderToggle: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    let provider: MDBListProvider

    private var binding: Binding<Bool> {
        Binding(
            get: {
                switch provider {
                case .trakt: return mdblist.settings.showTrakt
                case .imdb: return mdblist.settings.showImdb
                case .tmdb: return mdblist.settings.showTmdb
                case .letterboxd: return mdblist.settings.showLetterboxd
                case .tomatoes: return mdblist.settings.showTomatoes
                case .audience: return mdblist.settings.showAudience
                case .metacritic: return mdblist.settings.showMetacritic
                case .myanimelist: return mdblist.settings.showMyAnimeList
                }
            },
            set: { newValue in
                switch provider {
                case .trakt: mdblist.settings.showTrakt = newValue
                case .imdb: mdblist.settings.showImdb = newValue
                case .tmdb: mdblist.settings.showTmdb = newValue
                case .letterboxd: mdblist.settings.showLetterboxd = newValue
                case .tomatoes: mdblist.settings.showTomatoes = newValue
                case .audience: mdblist.settings.showAudience = newValue
                case .metacritic: mdblist.settings.showMetacritic = newValue
                case .myanimelist: mdblist.settings.showMyAnimeList = newValue
                }
            }
        )
    }

    var body: some View {
        SettingsToggleCard(title: provider.fullName, subtitle: "", isOn: binding)
    }
}

private struct MDBListKeyEditor: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    let onDone: () -> Void

    @State private var key = ""
    @State private var validating = false
    @State private var status: String?

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: CueSpacing.xl) {
                Text("MDBList API Key")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Get your key at mdblist.com/preferences")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)

                SecureField("Paste API key", text: $key)
                    .font(.system(size: 24))
                    .frame(maxWidth: 760)

                if let status {
                    Text(status)
                        .font(.system(size: 20))
                        .foregroundStyle(status.hasPrefix("Valid") ? CuePrimitives.success : CuePrimitives.error)
                }

                HStack(spacing: CueSpacing.lg) {
                    Button(action: verifyAndSave) {
                        if validating { ProgressView().tint(theme.palette.onSecondary) }
                        else { Text("Verify & Save") }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !mdblist.settings.apiKey.isEmpty {
                        Button("Remove", role: .destructive) {
                            mdblist.settings.apiKey = ""
                            onDone()
                        }
                    }
                    Button("Cancel", role: .cancel, action: onDone)
                }
                .font(.system(size: 24, weight: .semibold))
            }
            .padding(CueSpacing.huge)
        }
        .onAppear { key = mdblist.settings.apiKey }
        // Same as Cancel — dismiss without saving.
        .onExitCommand { onDone() }
    }

    private func verifyAndSave() {
        guard !validating else { return }
        validating = true
        status = nil
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        Task {
            let valid = await MDBListService.validate(apiKey: trimmed)
            validating = false
            if valid {
                mdblist.settings.apiKey = trimmed
                status = "Valid — saved."
                onDone()
            } else {
                status = "Invalid key or network error."
            }
        }
    }
}

/// A small curated ISO-639-1 language list for the TMDB language picker.
enum TMDBLanguages {
    static let options = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "hi", "ru", "ar"]

    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}

/// Shared card background for integration rows. Reads `isFocused` so that when
/// the row is the label of a focusable Button (which `PlainCardButtonStyle`
/// otherwise strips of all focus chrome) it still shows the fill + accent ring.
/// On non-focusable rows `isFocused` stays false, giving a plain static card.
private struct IntegrationRowBackground: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, CueSpacing.lg)
            .frame(minHeight: 68)
            // Leading, not the default centre: every other row in these panes
            // is left-aligned, so a connected-account row (Trakt's and SIMKL's
            // both use this) sat centred in the middle of a left-aligned list.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                    .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 4)
            )
    }
}

extension View {
    /// Shared, focus-aware card background for integration rows.
    func integrationRowBackground(_ theme: ThemeManager) -> some View {
        modifier(IntegrationRowBackground())
    }
}
