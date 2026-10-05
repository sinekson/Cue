import SwiftUI

/// First launch: sign in (`NuvioSignInView`: the QR code first, email as
/// the fallback), or carry on without an account — a first-class option
/// rather than a dead end: the default add-ons are guaranteed, so the app is
/// usable immediately, and the add-ons offer follows.
///
/// Shown once, before anything else, and only when nobody is signed in.
struct WelcomeView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var account: NuvioAccountManager
    @ObservedObject var addonManager: AddonManager
    let onFinished: () -> Void

    /// `offerAddons` and `addAddons` are only reachable from "Continue
    /// without an account". Someone who SIGNED IN has their add-ons arriving
    /// from their account moments later, so asking them to add some would be
    /// both redundant and confusing.
    private enum Step: Equatable { case signIn, offerAddons, addAddons }
    @State private var step: Step =
        ProcessInfo.processInfo.arguments.contains("-welcomeOfferDemo") ? .offerAddons : .signIn
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
                            onSignedIn: onFinished,
                            onContinueWithout: { step = .offerAddons })
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
                .font(FusionType.pageTitle(theme.font))
                .foregroundStyle(theme.palette.textPrimary)
            Text("Add-ons are where Cue gets its catalogs, artwork and streams. Cinemeta and OpenSubtitles are already installed. You can add more from your phone now — no typing on the remote — or any time from Settings → Add-ons.")
                .font(FusionType.bodyText(theme.font))
                .foregroundStyle(theme.palette.textSecondary)
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
