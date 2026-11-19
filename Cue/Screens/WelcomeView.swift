import SwiftUI

/// First launch: sign in (`NuvioSignInView`: the QR code first, email as
/// the fallback), or carry on without an account — a first-class option
/// rather than a dead end: the default add-ons are guaranteed, so the app is
/// usable immediately, and the add-ons offer follows. Then a TMDB key,
/// required: Home's rows, Search, Discover and the pictures are TMDB's
/// (`WelcomeKeyStep`; a key that arrives with the account goes on by
/// itself).
///
/// Shown once, before anything else, and only when nobody is signed in.
struct WelcomeView: View {
    @ObservedObject var account: NuvioAccountManager
    @ObservedObject var addonManager: AddonManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    let onFinished: () -> Void

    /// `offerAddons` and `addAddons` are only reachable from "Continue
    /// without an account". Someone who SIGNED IN has their add-ons arriving
    /// from their account moments later, so asking them to add some would be
    /// both redundant and confusing.
    private enum Step: Equatable { case signIn, tmdbKey(signedIn: Bool), offerAddons, addAddons }
    @State private var step: Step = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-welcomeOfferDemo") { return .offerAddons }
        if args.contains("-welcomeKeyDemo") { return .tmdbKey(signedIn: false) }
        return .signIn
    }()

    /// After signing in or carrying on: the key if there's none yet.
    private func afterAccount(signedIn: Bool) {
        if !tmdb.settings.isUsable { step = .tmdbKey(signedIn: signedIn) }
        else if signedIn { onFinished() }
        else { step = .offerAddons }
    }
    /// The offer's primary action holds focus, so a Select arriving as the
    /// screen appears takes the additive choice rather than dismissing it.
    @FocusState private var offerFocus: Bool

    var body: some View {
        switch step {
        case .signIn:
            // The shared sign-in screen (also Settings → Account's).
            // Signing in finishes onboarding — only from here: a session
            // restored in the background must not tear the add-ons step away
            // from someone who chose to carry on without an account.
            NuvioSignInView(account: account, title: "Welcome to Cue",
                            onSignedIn: { afterAccount(signedIn: true) },
                            onContinueWithout: { afterAccount(signedIn: false) })
        case .tmdbKey(let signedIn):
            WelcomeKeyStep { signedIn ? onFinished() : (step = .offerAddons) }
        case .offerAddons, .addAddons:
            ZStack {
                ATVBackground()
                Group {
                    if step == .offerAddons {
                        addonOffer
                    } else {
                        AddonPhoneAddView(addonManager: addonManager, onDone: onFinished)
                    }
                }
                .padding(CueSpacing.huge)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Add-ons offer

    private var addonOffer: some View {
        VStack(spacing: CueSpacing.lg) {
            Text("Add add-ons?")
                .font(FusionType.pageTitle)
                .foregroundStyle(CuePalette.textPrimary)
            Text("Add-ons are where Cue gets its streams. Cinemeta and OpenSubtitles are already installed. You can add more from your phone now — no typing on the remote — or any time from Settings → Add-ons.")
                .font(FusionType.bodyText)
                .foregroundStyle(CuePalette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: CueSpacing.md) {
                Button("Add add-ons now") { step = .addAddons }
                    .focused($offerFocus)
                Button("Later, in Settings", action: onFinished)
            }
            .padding(.top, CueSpacing.sm)
            .onAppear { offerFocus = true }
        }
    }
}

/// Onboarding's TMDB key: Cue's rows, Search, Discover and the pictures
/// come from TMDB, so there's no carrying on without one. Sent from a phone
/// (this TV serves a one-field page, its address as a QR: `KeyHandoffServer`)
/// or typed; checked before it's kept. A key arriving another way (the
/// account's sync) goes on by itself.
struct WelcomeKeyStep: View {
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    let onDone: () -> Void

    @StateObject private var server = ServiceKey.tmdb.handoffServer()
    @State private var keyboard: KeyboardRequest?
    @State private var checking = false
    @State private var failed = false
    @State private var finished = false

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: CueSpacing.lg) {
                Text("Add your TMDB key")
                    .font(FusionType.pageTitle)
                    .foregroundStyle(CuePalette.textPrimary)
                Text("Home's rows, Search, Discover and the pictures all come from TMDB. "
                     + ServiceKey.tmdb.howTo)
                    .font(FusionType.bodyText)
                    .foregroundStyle(CuePalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1000)
                    .fixedSize(horizontal: false, vertical: true)
                if let address = server.address {
                    QRCodeView(string: address, side: 320)
                    Text("Scan with your phone, or open \(address) in its browser, on the same network.")
                        .font(.system(size: 22))
                        .foregroundStyle(CuePalette.textSecondary)
                } else if let error = server.lastError {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(CuePrimitives.error)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                } else {
                    LoadingSpinner().frame(height: 320)
                }
                Text(checking ? "Checking the key…" : failed ? "That key didn't work. Check you copied all of it." : " ")
                    .font(.system(size: 22))
                    .foregroundStyle(failed ? CuePrimitives.error : CuePalette.textSecondary)
                Button("Type the Key Instead") {
                    keyboard = KeyboardRequest(text: "", placeholder: "TMDB API key") { text in
                        check(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                .disabled(checking)
            }
            .padding(CueSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        }
        .onAppear {
            ServiceKey.tmdb.serve(server) { tmdb.setAPIKey($0) }
            if tmdb.settings.isUsable { finish() }
        }
        .onDisappear { server.stop() }
        .onChange(of: tmdb.settings.isUsable) { _, usable in if usable { finish() } }
    }

    private func check(_ candidate: String) {
        guard !candidate.isEmpty else { return }
        checking = true
        failed = false
        Task {
            let valid = await ServiceKey.tmdb.validate(candidate)
            checking = false
            if valid { tmdb.setAPIKey(candidate) } else { failed = true }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }
}

/// Whether the welcome screen has been shown and dismissed.
///
/// Its own flag rather than "is signed in": someone who chose to carry on
/// without an account must not be asked again on every launch.
enum OnboardingState {
    private static let key = "cue.onboarding.completed.v1"

    static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// True on a fresh install with nobody signed in. An install that is
    /// already signed in (restored session, or an upgrade from a build that
    /// predates this screen) skips it — the screen would have nothing to ask.
    static func shouldShow(signedIn: Bool) -> Bool {
        !completed && !signedIn
    }
}
