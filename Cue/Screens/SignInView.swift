import SwiftUI

/// SIGNING IN TO NUVIO — one screen, from the first launch and from
/// Settings → Account: the QR code in the middle (scanned with a phone, no
/// password typed on the TV — see `NuvioAccountManager.signIn`), and below
/// it "Use email instead" (the same screen turns into the email form) and,
/// on the first launch only, "Continue without an account". From Settings
/// there is no such option: Back leaves, as everywhere.
///
/// Starts the QR sign-in as it appears, stops it as it goes; signing in by
/// either route calls `onSignedIn`.
struct NuvioSignInView: View {
    @ObservedObject var account: NuvioAccountManager
    /// The heading ("Welcome to Cue" on the first launch).
    var title = "Sign in to Nuvio"
    let onSignedIn: () -> Void
    /// First launch only: carry on without an account.
    var onContinueWithout: (() -> Void)? = nil

    @State private var usingEmail = false
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false

    private enum Focus: Hashable { case email, withoutAccount, emailField, passwordField, signIn }
    @FocusState private var focus: Focus?

    /// The sign-in address without scheme or query — what someone would
    /// actually type into a phone.
    private static var displayHost: String {
        let base = NuvioConfig.tvLoginWebBaseURL
        return base
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "?").first ?? base
    }

    var body: some View {
        ZStack {
            ATVBackground()
            Group {
                if usingEmail { emailForm } else { qrScreen }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Signing in by ANY route: the QR poll completes on its own
        // timeline, so the auth state is what catches it.
        .onChange(of: account.authState.isSignedIn) { _, signedIn in
            if signedIn { onSignedIn() }
        }
        .onAppear { if account.qrLogin == nil { account.startQRLogin() } }
        .onDisappear { account.cancelQRLogin() }
    }

    // MARK: QR

    private var qrScreen: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(Color.white)

            Group {
                if let qr = account.qrLogin {
                    VStack(spacing: 26) {
                        QRCodeView(string: qr.webURL, side: 300)
                            .padding(20)
                            .background(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
                                .fill(Color.white))
                        // The typed-in fallback: the bare address and the
                        // code shown separately (the QR's URL embeds it).
                        Text("Scan with your phone, or go to \(Self.displayHost) and enter")
                            .font(.system(size: FixedFocusMetrics.textSize))
                            .foregroundStyle(Color.white.opacity(0.7))
                        Text(qr.code)
                            .font(.system(size: 36, weight: .semibold, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(account.errorMessage ?? qr.statusText)
                            .font(.system(size: 21))
                            .foregroundStyle(account.errorMessage == nil ? Color.white.opacity(0.5)
                                                                         : CuePrimitives.red300)
                    }
                } else if NuvioConfig.isConfigured {
                    CueLoadingView(label: "Preparing sign-in").frame(height: 340)
                } else {
                    // No backend in this build — say so instead of a code that
                    // can never complete.
                    Text("Accounts aren't configured in this build.")
                        .font(.system(size: FixedFocusMetrics.textSize))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .frame(height: 340)
                }
            }
            .padding(.top, 44)

            HStack(spacing: 24) {
                if NuvioConfig.isConfigured {
                    DetailActionButton(icon: "envelope", title: "Use email instead", isPrimary: true,
                                       lit: focus == .email) {
                        account.errorMessage = nil
                        usingEmail = true
                    }
                    .focused($focus, equals: .email)
                }
                if let onContinueWithout {
                    DetailActionButton(icon: "arrow.right", title: "Continue without an account",
                                       isPrimary: true, lit: focus == .withoutAccount) {
                        account.cancelQRLogin()
                        onContinueWithout()
                    }
                    .focused($focus, equals: .withoutAccount)
                }
            }
            .padding(.top, 48)
            .focusSection()
        }
    }

    // MARK: Email + password

    private var emailForm: some View {
        VStack(spacing: 24) {
            Text("Sign in with email")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.bottom, 20)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .focused($focus, equals: .emailField)
                .frame(maxWidth: 700)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .passwordField)
                .frame(maxWidth: 700)

            if let error = account.errorMessage {
                Text(error)
                    .font(.system(size: 21))
                    .foregroundStyle(CuePrimitives.red300)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 800)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DetailActionButton(icon: "person.crop.circle", title: signingIn ? "Signing in…" : "Sign in",
                               isPrimary: true, lit: focus == .signIn) {
                guard !signingIn else { return }
                signingIn = true
                Task {
                    await account.signIn(email: email, password: password)
                    signingIn = false
                    // Cleared either way: no reason to keep it in memory.
                    password = ""
                }
            }
            .focused($focus, equals: .signIn)
            .padding(.top, 20)
        }
        .onAppear { focus = .emailField }
        // Back returns to the code.
        .onExitCommand {
            account.errorMessage = nil
            password = ""
            usingEmail = false
        }
    }
}
