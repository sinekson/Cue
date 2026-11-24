import SwiftUI

// MARK: - Services (Settings → Accounts → TMDB, MDBList)

/// A service's key: what it's for, where to get one, how to check and store it.
enum ServiceKey {
    case tmdb, mdblist

    var name: String { self == .tmdb ? "TMDB" : "MDBList" }

    var about: String {
        switch self {
        case .tmdb:
            return "Search, artwork, cast and details for every title."
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

extension MDBListUsage.Snapshot {
    /// "312 of 1,000".
    var requestsToday: String { "\((limit - remaining).formatted()) of \(limit.formatted())" }
}

extension ServiceKey {
    /// The key's last four, the rest dots: enough to tell keys apart, not
    /// enough to copy off a photo of the screen.
    static func masked(_ key: String) -> String {
        String(repeating: "•", count: 10) + key.suffix(4)
    }
}

/// Scan-to-enter for a key: this Apple TV serves a one-field page on the
/// local network and shows its address as a QR. Neither service has a
/// device login, so the hand-off happens between the phone and the TV.
struct KeyHandoffPage: View {
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
                    .foregroundStyle(CuePalette.textPrimary)

                if server.accepted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 90))
                        .foregroundStyle(CuePrimitives.success)
                    Text("Key saved.")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(CuePalette.textPrimary)
                } else if let address = server.address {
                    Text("Scan with your phone, or open \(address) in its browser. Both devices have to be on the same network.")
                        .font(.system(size: 22))
                        .foregroundStyle(CuePalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                    QRCodeView(string: address, side: 360)
                    Text(address)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(CuePalette.secondary)
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
