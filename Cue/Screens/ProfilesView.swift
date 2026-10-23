import SwiftUI
import UIKit

extension Color {
    /// Parses a "#RRGGBB" profile color, falling back to blue.
    init(profileHex: String) {
        var s = profileHex
        if s.hasPrefix("#") { s.removeFirst() }
        self.init(hex: UInt32(s, radix: 16) ?? 0x1E88E5)
    }
}

// MARK: - Avatar

/// A profile's avatar: catalog image if it has one, otherwise a colored circle
/// with the name's initial.
struct ProfileAvatarView: View {
    @EnvironmentObject private var profiles: ProfileStore
    let profile: UserProfile
    var size: CGFloat = 140

    @State private var image: UIImage?

    private var avatarURLString: String? { profiles.avatarURL(for: profile) }

    var body: some View {
        ZStack {
            Circle().fill(Color(profileHex: profile.avatarColorHex))
            if let image {
                // Chosen avatar fully REPLACES the initial (drawn over the
                // colored circle, clipped to it).
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else if avatarURLString == nil {
                // No avatar chosen → colored initial. When an avatar IS chosen
                // but still loading, we deliberately show ONLY the circle (no
                // initial) so the "P" never flashes before the icon.
                initial
            }
        }
        .frame(width: size, height: size)
        .task(id: avatarURLString) { await loadAvatar() }
    }

    /// Cached avatar load (via the shared ImageCache) so a decoded avatar shows
    /// instantly on every re-appearance instead of re-downloading and flashing.
    private func loadAvatar() async {
        guard let urlString = avatarURLString, let url = URL(string: urlString) else {
            image = nil
            return
        }
        if let cached = ImageCache.shared.image(for: urlString) {
            image = cached
            return
        }
        // Through the pipeline, not URLSession.shared + UIImage(data:): the
        // avatar renders at ≤120pt, and the raw path decoded the original
        // full-size (lazily, ON the render path) and then re-encoded it to
        // JPEG on the main actor inside insert(). Downsampled decode happens
        // off-main; the original bytes go to disk as-is.
        if let disk = await ImageCache.shared.diskImage(for: urlString, budget: 256) {
            if !Task.isCancelled { image = disk }
            return
        }
        guard let data = try? await ImageCache.shared.download(url),
              !Task.isCancelled else { return }
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageCache.decodeDownsampled(data, budget: 256)
        }.value
        guard let decoded, !Task.isCancelled else { return }
        ImageCache.shared.insert(decoded, for: urlString, data: data)
        image = decoded
    }

    private var initial: some View {
        Text(profile.initial)
            .font(.system(size: size * 0.42, weight: .heavy))
            .foregroundStyle(.white)
    }
}

// MARK: - "Who's watching?" gate

/// "Who's watching?" — at launch and from the top bar's avatar: only for
/// switching (a locked profile asks its PIN). Profiles are added and edited
/// in Settings → Nuvio → Profiles.
struct ProfileGateView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    let onSelected: () -> Void
    /// Back handler when the gate is opened as a MODAL (the top bar's
    /// avatar). nil on cold launch, where Back is a no-op.
    var onCancel: (() -> Void)? = nil

    @State private var pinProfile: UserProfile?
    // Open with focus on the profile you last used, so the trackpad starts on a
    // sensible tile rather than an arbitrary one.
    @FocusState private var focusedProfile: Int?
    var body: some View {
        ZStack {
            ATVBackground()
            // PIN entry is rendered INLINE (not a nested fullScreenCover) so it
            // reliably appears every time a locked profile is entered — the
            // nested cover only presented on the first launch, so later profile
            // switches skipped the PIN.
            if let locked = pinProfile {
                PinEntryView(
                    title: "Enter PIN",
                    subtitle: locked.name,
                    onSubmit: { pin in
                        let outcome = await profiles.verifyPin(id: locked.id, pin: pin)
                        if outcome.unlocked {
                            pinProfile = nil
                            profiles.setActive(locked.id)
                            onSelected()
                            return nil
                        }
                        if outcome.retryAfterSeconds > 0 {
                            return "Too many attempts. Try again in \(outcome.retryAfterSeconds)s."
                        }
                        return outcome.message ?? "Incorrect PIN"
                    },
                    onCancel: { pinProfile = nil }
                )
            } else {
                VStack(spacing: CueSpacing.huge) {
                    Text("Who's watching?")
                        .font(.system(size: 58, weight: .heavy))
                        .foregroundStyle(theme.palette.textPrimary)

                    HStack(alignment: .top, spacing: CueSpacing.xl) {
                        ForEach(profiles.profiles) { profile in
                            Button { select(profile) } label: {
                                GateTile(title: profile.name, locked: profile.pinEnabled) {
                                    ProfileAvatarView(profile: profile)
                                }
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .focused($focusedProfile, equals: profile.id)
                        }
                    }
                    .defaultFocus($focusedProfile, profiles.active.id)
                }
                .padding(CueSpacing.huge)
            }
        }
        // On cold launch this is the very first screen — there's nothing to
        // go back to, so Back is a no-op instead of falling through to the
        // system (which would otherwise exit the app). Opened from the rail
        // or Settings, Back closes it and keeps the current profile.
        // Adding and editing profiles: Settings → Nuvio → Profiles.
        .onExitCommand { onCancel?() }
        .task { await profiles.loadAvatarCatalog() }
    }

    private func select(_ profile: UserProfile) {
        if profile.pinEnabled {
            pinProfile = profile
        } else {
            profiles.setActive(profile.id)
            onSelected()
        }
    }
}

/// Avatar + caption tile with a focus ring, used across profile screens.
private struct GateTile<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    var locked: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: CueSpacing.md) {
            ZStack(alignment: .bottomTrailing) {
                content
                    .overlay(
                        Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 6)
                    )
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(Circle().fill(.black.opacity(0.65)))
                }
            }
            .focusLift(CueFocus.avatar, isFocused)

            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 160)
        }
    }
}

// MARK: - PIN entry

/// Reusable 4-digit PIN pad. `onSubmit` returns an error string to display, or
/// nil on success.
struct PinEntryView: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    var subtitle: String?
    let onSubmit: (String) async -> String?
    let onCancel: () -> Void

    @State private var digits = ""
    @State private var error: String?
    @State private var busy = false

    private let pinLength = 4

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: CueSpacing.xl) {
                Text(title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                }

                HStack(spacing: CueSpacing.lg) {
                    ForEach(0..<pinLength, id: \.self) { i in
                        Circle()
                            .fill(i < digits.count ? theme.palette.secondary : .white.opacity(0.2))
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(.vertical, CueSpacing.md)

                if let error {
                    Text(error)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(CuePrimitives.error)
                }

                VStack(spacing: CueSpacing.md) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: CueSpacing.md) {
                            ForEach(1...3, id: \.self) { col in
                                digitButton("\(row * 3 + col)")
                            }
                        }
                    }
                    HStack(spacing: CueSpacing.md) {
                        actionButton(systemName: "delete.left") { if !digits.isEmpty { digits.removeLast() } }
                        digitButton("0")
                        actionButton(systemName: "xmark") { onCancel() }
                    }
                }
                // Not `.disabled(busy)`: disabling the whole keypad mid-press
                // dropped focus, and left the page's onExitCommand with no
                // focused descendant. `append` ignores digits while busy.
            }
            .padding(CueSpacing.huge)
        }
        // Back cancels (same as the on-screen xmark) instead of falling
        // through to the system, which would otherwise exit the app.
        .onExitCommand { onCancel() }
    }

    private func digitButton(_ digit: String) -> some View {
        Button { append(digit) } label: {
            Text(digit)
                .font(.system(size: 40, weight: .semibold))
        }
        .buttonStyle(PinKeyStyle())
    }

    private func actionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 34, weight: .semibold))
        }
        .buttonStyle(PinKeyStyle())
    }

    private func append(_ digit: String) {
        guard digits.count < pinLength, !busy else { return }
        error = nil
        digits += digit
        if digits.count == pinLength { submit() }
    }

    private func submit() {
        busy = true
        let entered = digits
        Task {
            let result = await onSubmit(entered)
            if let result {
                error = result
                digits = ""
            }
            busy = false
        }
    }
}

private struct PinKeyStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    func makeBody(configuration: Configuration) -> some View {
        // ONE foregroundStyle. An inner `.foregroundStyle(.white)` used to sit
        // above this and resolve the label first, so the outer conditional never
        // reached the glyph: a focused key drew white-on-0.9-white and the digit
        // vanished — on the keypad guarding a profile's PIN.
        configuration.label
            .foregroundStyle(isFocused ? FlatControl.contentOnFocus : FlatControl.content)
            .frame(width: 90, height: 90)
            .background(Circle().fill(isFocused ? FlatControl.focus : FlatControl.rest))
            .focusLift(CueFocus.control, isFocused)
            .cardPressDip(configuration.isPressed)
    }
}
