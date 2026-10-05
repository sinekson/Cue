import SwiftUI

/// Settings → Account. Nuvio — signed out, Sign in (the first launch's
/// sign-in screen); signed in, Sync now (its value is the state: "2 min
/// ago", "Syncing…", "Failed") and Sign out (its value: the email), the box
/// showing the account's state. Then clearing the watch history. (Profiles, and what they share with the
/// primary one: the top bar's avatar → Edit.)
struct AccountSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: NuvioAccountManager

    @State private var confirmSignOut = false
    @State private var confirmClearHistory = false

    var body: some View {
        SettingsPage(place: SettingsCategory.account.place, subtitle: SettingsCategory.account.subtitle) {
            SettingsSection(title: "Account") {
                if !account.authState.isSignedIn {
                    SettingsLinkRow(
                        title: "Sign in",
                        description: "Sign in to your Nuvio account to sync profiles, Continue Watching, your library, add-ons and settings with your other devices.",
                        preview: AnyView(AccountStateCard(state: .signedOut, email: ""))
                    ) { SignInPage(account: account) }
                }
                if case .signedIn(_, let email) = account.authState {
                    if let sync = NuvioSyncManager.shared {
                        SyncNowRow(sync: sync, email: email)
                    }
                    SettingsButtonRow(
                        title: "Sign out",
                        description: "Signed in as \(email.isEmpty ? "your Nuvio account" : email). Everything stays on this TV, but it stops syncing until you sign in again.",
                        value: email,
                        preview: AnyView(AccountStateCard(state: .synced, email: email))
                    ) { confirmSignOut = true }
                }
            }

            if account.authState.isSignedIn, let sync = NuvioSyncManager.shared {
                SettingsSection(title: "Watch history") {
                    SettingsButtonRow(
                        title: "Clear watch history",
                        description: "Removes everything from Continue Watching and every watched mark — on this TV and in your account, so on your other devices too. This can't be undone."
                    ) { confirmClearHistory = true }
                }
                .alert("Clear watch history?", isPresented: $confirmClearHistory) {
                    Button("Clear everywhere", role: .destructive) {
                        Task { await sync.clearWatchHistoryEverywhere() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Continue Watching and every watched mark go, on all your devices. This can't be undone.")
                }
            }
        }
        .alert("Sign out?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { account.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your watch progress, library and add-ons stay on this TV, but they'll stop syncing until you sign in again.")
        }
    }
}

/// The sign-in screen, pushed; back to Account once signed in.
private struct SignInPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var account: NuvioAccountManager

    var body: some View {
        NuvioSignInView(account: account, onSignedIn: { dismiss() })
    }
}

/// Sync now: the one sync action. Its value is the state; the box shows it
/// too. (Sync also runs on its own while the app is open.)
private struct SyncNowRow: View {
    @ObservedObject var sync: NuvioSyncManager
    let email: String

    var body: some View {
        // Re-rendered every 30 s, so "2 min ago" keeps counting.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            SettingsButtonRow(
                title: "Sync now",
                description: description,
                value: value(now: context.date),
                preview: AnyView(AccountStateCard(state: state, email: email))
            ) {
                Task { await sync.syncNow() }
            }
        }
    }

    private var state: AccountStateCard.State {
        if sync.isSyncing { return .syncing }
        return sync.lastSyncError == nil ? .synced : .failed
    }

    private var description: String {
        if let error = sync.lastSyncError, !sync.isSyncing {
            return "The last sync failed: \(error)"
        }
        return "Profiles, Continue Watching, your library, add-ons and settings sync on their own while Cue is open. This syncs right away."
    }

    private func value(now: Date) -> String {
        switch state {
        case .syncing: return "Syncing…"
        case .failed: return "Failed"
        case .signedOut: return ""
        case .synced:
            guard let last = sync.lastSyncedAt else { return "" }
            if now.timeIntervalSince(last) < 60 { return "Just now" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: last, relativeTo: now)
        }
    }
}

/// The box on the account's rows: a cloud showing the state (synced, syncing,
/// failed) with the email under it.
private struct AccountStateCard: View {
    enum State { case signedOut, synced, syncing, failed }
    let state: State
    let email: String

    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            VStack(spacing: 22) {
                Image(systemName: symbol)
                    .font(.system(size: 110, weight: .regular))
                    .foregroundStyle(state == .failed ? Color(CuePrimitives.error) : Color.white.opacity(0.8))
                    .symbolEffect(.pulse, isActive: state == .syncing)
                if !email.isEmpty {
                    Text(email)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
    }

    private var symbol: String {
        switch state {
        case .signedOut: return "person.crop.circle"
        case .synced: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }
}

// MARK: - Shared pieces

/// One line of the sync log (Settings → Developer).
struct SyncLogRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let entry: NuvioSyncLogEntry

    var body: some View {
        HStack(spacing: CueSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(entry.timeLabel)
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(entry.area)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.palette.secondary)
                .frame(width: 90, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.background.opacity(0.32))
        )
    }

    private var icon: String {
        switch entry.level {
        case .info: return "circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: return theme.palette.textTertiary
        case .success: return CuePrimitives.success
        case .warning: return theme.palette.secondary
        case .failure: return CuePrimitives.error
        }
    }
}
