import SwiftUI

/// Email + password sign-in, used by the Nuvio account panel as the
/// alternative to its QR flow. The backend already accepts a password grant;
/// only a way to type one was missing.
///
/// Presented as a full-screen cover like the QR pages it sits beside, because a
/// tvOS keyboard needs the room and the field it is editing must not be under
/// the settings card's own scroll.
struct EmailSignInView: View {
    @EnvironmentObject private var theme: ThemeManager

    /// "Nuvio" / "Stremio" — titles the page and names the account in the copy.
    let service: String
    @Binding var email: String
    @Binding var password: String
    /// Progress or failure text under the fields; failures are drawn in the
    /// error colour.
    var status: String?
    var isError: Bool = false
    var busy: Bool = false
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private enum Field: Hashable { case email, password, submit }
    @FocusState private var focused: Field?

    var body: some View {
        ZStack {
            ATVBackground()

            VStack(spacing: CueSpacing.xl) {
                VStack(spacing: CueSpacing.sm) {
                    Text("Sign in to \(service)")
                        .font(.system(size: 48, weight: .heavy))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("Enter the email and password for your \(service) account.")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }

                VStack(spacing: CueSpacing.md) {
                    // `.username` / `.password` are what let tvOS offer the
                    // saved credential and the iPhone keyboard hand-off, which
                    // is the difference between typing an address on a remote
                    // and not having to.
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .onSubmit { focused = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .onSubmit(submit)
                }
                .font(.system(size: 26))
                .frame(maxWidth: 760)

                AccountPrimaryButton(title: busy ? "Signing In…" : "Sign In",
                                     systemImage: "arrow.right.circle.fill",
                                     action: submit)
                    .focused($focused, equals: .submit)

                if let status, !status.isEmpty {
                    Text(status)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isError ? CuePrimitives.error : theme.palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)
                }

                Text("Press Menu to go back")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(CueSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: onCancel)
        .onAppear { focused = .email }
    }

    /// Nothing here is ever `.disabled`, deliberately. A disabled view is not
    /// focusable on tvOS, so disabling the button the moment a sign-in starts —
    /// or while the fields are empty — strands focus on a control that vanishes
    /// from under it. The guard lives here instead: an empty or in-flight
    /// submit is simply ignored.
    private func submit() {
        guard !busy, !email.isEmpty, !password.isEmpty else { return }
        onSubmit()
    }
}
