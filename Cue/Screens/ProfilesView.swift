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

/// "Who's watching?" — on the launch curtain (`LaunchCurtain`), after 4 hours
/// away and from the top bar's avatar: for switching (a locked profile asks
/// its PIN) and adding one — Add Profile last, below 5 (`ProfileSetup`, the
/// guided steps, ending in the new profile picked). Editing: holding an
/// avatar opens that profile's Settings page over the gate (a locked one
/// asks its PIN first; nothing switches). The picked avatar flies to the top bar's as Home dissolves in;
/// Home not ready yet for that profile (the launch's preload, or another
/// profile's after a switch — `LaunchPreloader.picked`), it waits in the
/// middle, breathing as the launch's play.
struct ProfileGate: View {
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var launch = LaunchPreloader.shared
    let mode: LaunchPreloader.GateMode
    /// The flight starts: the curtain's background dissolves off Home.
    let onFly: () -> Void

    /// The background going as the avatar flies — on the flight's time.
    static let dissolve: Animation = .easeInOut(duration: Motion.presentDuration)
    static let avatarSize: CGFloat = 180
    /// Focused, as the cards' moving focus.
    static let focusScale: CGFloat = 1.05
    /// Waiting, as the launch's play.
    static let breath: (scale: CGFloat, duration: Double) = (1.08, 0.8)

    private enum Phase { case choosing, waiting, flying }
    @State private var phase = Phase.choosing
    @State private var picked: UserProfile?
    @State private var pinProfile: UserProfile?
    /// Each avatar's centre on the screen — where the picked one sets off.
    @State private var centres: [Int: CGPoint] = [:]
    @State private var flyerCentre = CGPoint.zero
    @State private var flyerScale: CGFloat = 1
    @State private var breathing = false
    @State private var screen = CGSize.zero
    @State private var adding = false
    /// The PIN asked to edit a profile (held), not to pick it.
    @State private var pinToEdit = false
    /// A held profile's Settings page over the gate (by id).
    @State private var editing: Int?
    /// The avatar rested on long enough for its "Hold to edit" hint.
    @State private var hinted: Int?
    /// How long focus rests on an avatar before its hint shows.
    static let hintDelay: Duration = .seconds(0.5)
    @FocusState private var focused: Int?
    /// Add Profile's focus id (profiles count up from 1).
    private static let addID = 0

    var body: some View {
        ZStack {
            if let id = editing {
                ATVSettingsView(barFocused: false, root: AnyView(ProfileSettingsPage(profileID: id))) {
                    editing = nil
                    // Back on the held avatar (deleted: the active one).
                    let back = profiles.profiles.contains { $0.id == id } ? id : profiles.activeProfileID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = back }
                }
                .environment(\.fromProfileGate, true)
                .transition(.opacity)
            } else if adding {
                ProfileSetup(background: false, finishTitle: "Start Watching", onFinish: { created in
                    adding = false
                    choose(created, from: CGPoint(x: screen.width / 2, y: screen.height / 2))
                }, onCancel: {
                    adding = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = Self.addID }
                })
                .transition(.opacity)
            } else if let locked = pinProfile {
                PinEntryView(
                    title: "Enter PIN",
                    subtitle: locked.name,
                    background: false,
                    onSubmit: { pin in
                        let outcome = await profiles.verifyPin(id: locked.id, pin: pin)
                        if outcome.unlocked {
                            pinProfile = nil
                            if pinToEdit {
                                pinToEdit = false
                                editing = locked.id
                            } else {
                                choose(locked, from: CGPoint(x: screen.width / 2, y: screen.height / 2))
                            }
                            return nil
                        }
                        if outcome.retryAfterSeconds > 0 {
                            return "Too many attempts. Try again in \(outcome.retryAfterSeconds)s."
                        }
                        return outcome.message ?? "Incorrect PIN"
                    },
                    onCancel: {
                        pinProfile = nil
                        pinToEdit = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = locked.id }
                    }
                )
                .transition(.opacity)
            } else {
                chooser
                    .transition(.opacity)
            }
            if let picked, phase != .choosing {
                flyer(picked)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
        .animation(Motion.fade, value: pinProfile?.id)
        .animation(Motion.fade, value: adding)
        .animation(Motion.fade, value: editing)
        // At launch and coming back there's nothing to go back to (the
        // window drops it — `BackCatch`); from the top bar, Back closes it.
        .onExitCommand { if phase == .choosing, !adding, editing == nil { launch.cancelGate() } }
        .onChange(of: launch.ready) { _, ready in if ready, phase == .waiting { fly() } }
        .onAppear {
            // Over a page that just lost its focus (the top bar's avatar):
            // asked, once the gate is there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = profiles.activeProfileID }
        }
        .task { await profiles.loadAvatarCatalog() }
    }

    private var chooser: some View {
        VStack(spacing: 72) {
            Text("Who's watching?")
                .font(.system(size: 57, weight: .semibold))
                .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
            HStack(alignment: .top, spacing: 40) {
                ForEach(profiles.profiles) { profile in
                    Button { select(profile) } label: {
                        GateTile(profile: profile, size: Self.avatarSize,
                                 away: picked?.id == profile.id,
                                 hint: hinted == profile.id && phase == .choosing) { centre in
                            centres[profile.id] = centre
                        }
                    }
                    .buttonStyle(GateTileStyle())
                    .focused($focused, equals: profile.id)
                    // Held: its Settings page.
                    .holdMenu(focused: focused == profile.id, direct: true) {
                        [MenuEntry(title: "Edit Profile", icon: "gearshape") { edit(profile) }]
                    }
                }
                if profiles.canAddProfile {
                    Button { adding = true } label: {
                        GateAddTile(size: Self.avatarSize)
                    }
                    .buttonStyle(GateTileStyle())
                    .focused($focused, equals: Self.addID)
                }
            }
            .defaultFocus($focused, profiles.activeProfileID)
        }
        .task(id: focused) {
            hinted = nil
            guard let id = focused, id > 0 else { return }
            try? await Task.sleep(for: Self.hintDelay)
            if !Task.isCancelled { hinted = id }
        }
        // The title and the other profiles go as the picked one leaves.
        .opacity(phase == .choosing ? 1 : 0)
        .animation(Motion.fade, value: phase == .choosing)
        .disabled(phase != .choosing)
    }

    /// The picked avatar, on its own over everything: waiting in the
    /// middle, then up to the top bar's.
    private func flyer(_ profile: UserProfile) -> some View {
        GateAvatarFace(profile: profile, size: Self.avatarSize, lit: phase == .waiting,
                       edges: phase != .flying)
            .scaleEffect(breathing ? Self.breath.scale : 1)
            .animation(breathing ? .easeInOut(duration: Self.breath.duration).repeatForever(autoreverses: true)
                       : Motion.focus, value: breathing)
            .scaleEffect(flyerScale)
            .position(flyerCentre)
            .allowsHitTesting(false)
    }

    /// A profile's page over the gate — a locked one's PIN first.
    private func edit(_ profile: UserProfile) {
        if profile.pinEnabled {
            pinToEdit = true
            pinProfile = profile
        } else {
            editing = profile.id
        }
    }

    private func select(_ profile: UserProfile) {
        if profile.pinEnabled {
            pinProfile = profile
        } else {
            choose(profile, from: centres[profile.id]
                   ?? CGPoint(x: screen.width / 2, y: screen.height / 2))
        }
    }

    /// Picked: the stores switch now (another profile), and the avatar
    /// flies once Home is ready for it — waiting in the middle till then.
    private func choose(_ profile: UserProfile, from start: CGPoint) {
        let switched = profile.id != profiles.activeProfileID
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            picked = profile
            flyerCentre = start
            flyerScale = Self.focusScale
            phase = .waiting
        }
        if switched { profiles.setActive(profile.id) }
        launch.picked(switched: switched)
        if launch.ready {
            fly()
            return
        }
        withAnimation(Motion.present) {
            flyerCentre = CGPoint(x: screen.width / 2, y: screen.height / 2)
            flyerScale = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.presentDuration) {
            if phase == .waiting { breathing = true }
        }
    }

    /// Up into the top bar's avatar, Home dissolving in under it.
    private func fly() {
        breathing = false
        phase = .flying
        onFly()
        if let target = TopBarAvatar.frame {
            withAnimation(Motion.present) {
                flyerCentre = CGPoint(x: target.midX, y: target.midY)
                flyerScale = target.width / Self.avatarSize
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.presentDuration) {
            launch.gateLanded()
        }
    }
}

/// A profile's avatar on the gate: the cards' edge — a thin rim at rest, the
/// bright edge and a soft shadow focused (Settings → Appearance → Card
/// outlines).
private struct GateAvatarFace: View {
    let profile: UserProfile
    let size: CGFloat
    let lit: Bool
    /// Off for the flight: the top bar's avatar has none.
    var edges = true

    var body: some View {
        let outlines = FixedFocusRing.outlines
        let bright = lit && outlines == .high
        ProfileAvatarView(profile: profile, size: size)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(bright ? 0.75 : 0.30), lineWidth: 2)
                    .opacity(outlines == .off || !edges ? 0 : 1)
            }
            .shadow(color: .black.opacity(lit && edges ? 0.45 : 0), radius: 18, y: 10)
    }
}

/// The gate's slots: the avatar, its name under it. One width for all, Add
/// Profile too, so with three the middle one sits under the title.
private enum GateSlot {
    static let nameGap: CGFloat = 22
    /// Wider than the avatar by this (room for a longer name).
    static let sideRoom: CGFloat = 60
    /// The name's step down while focused: the avatar's growth below it.
    static func step(_ size: CGFloat) -> CGFloat { size * (ProfileGate.focusScale - 1) / 2 }
}

/// A profile on the gate: its avatar, the cards' edge on it, the name under
/// it at a caption's levels; focused, 5 % larger with the bright edge and a
/// soft shadow.
private struct GateTile: View {
    @Environment(\.isFocused) private var isFocused
    let profile: UserProfile
    let size: CGFloat
    /// Picked: the avatar is the flyer now (`ProfileGate.flyer`).
    var away = false
    /// Rested on: "Hold to edit" under the name (its room always kept).
    var hint = false
    let onCentre: (CGPoint) -> Void

    var body: some View {
        VStack(spacing: GateSlot.nameGap) {
            ZStack(alignment: .bottomTrailing) {
                GateAvatarFace(profile: profile, size: size, lit: isFocused)
                if profile.pinEnabled {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                        .padding(10)
                        .background(Circle().fill(.black.opacity(0.65)))
                }
            }
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { onCentre($0) }
            .opacity(away ? 0 : 1)
            .scaleEffect(isFocused ? ProfileGate.focusScale : 1)
            .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
            VStack(spacing: 14) {
                Text(profile.name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(isFocused ? FixedFocusText.primary : FixedFocusText.secondary))
                    .lineLimit(1)
                // The section hints' look (`SectionHint`).
                Text("HOLD TO EDIT")
                    .font(.system(size: SectionHint.size, weight: SectionHint.weight))
                    .tracking(SectionHint.tracking)
                    .foregroundStyle(Color.white.opacity(SectionHint.opacity))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(hint ? 1 : 0)
                    .animation(Motion.fade, value: hint)
            }
            // Out of the grown avatar's way: by its growth below it.
            .offset(y: isFocused ? GateSlot.step(size) : 0)
            .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
        }
        .frame(width: size + GateSlot.sideRoom)
    }
}

/// Add Profile: a plus on a flat round plate the avatars' size, with their
/// rim, its name under it.
private struct GateAddTile: View {
    @Environment(\.isFocused) private var isFocused
    let size: CGFloat

    var body: some View {
        let outlines = FixedFocusRing.outlines
        VStack(spacing: GateSlot.nameGap) {
            Circle()
                .fill(isFocused ? FlatControl.focus : FlatControl.rest)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .foregroundStyle(isFocused ? FlatControl.contentOnFocus : FlatControl.content)
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.30), lineWidth: 2)
                        .opacity(outlines == .off || isFocused ? 0 : 1)
                }
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
                .scaleEffect(isFocused ? ProfileGate.focusScale : 1)
                .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
            Text("Add Profile")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.white.opacity(isFocused ? FixedFocusText.primary : FixedFocusText.secondary))
                .lineLimit(1)
                .offset(y: isFocused ? GateSlot.step(size) : 0)
                .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
        }
        .frame(width: size + GateSlot.sideRoom)
    }
}

/// A profile's Settings page opened over the gate: no Switch row (picking
/// switches).
private struct FromProfileGateKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var fromProfileGate: Bool {
        get { self[FromProfileGateKey.self] }
        set { self[FromProfileGateKey.self] = newValue }
    }
}

private struct GateTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.cardPressDip(configuration.isPressed)
    }
}

// MARK: - PIN entry

/// Reusable 4-digit PIN pad. `onSubmit` returns an error string to display, or
/// nil on success.
struct PinEntryView: View {
    let title: String
    var subtitle: String?
    /// Off on the gate (the curtain's background is under it).
    var background = true
    let onSubmit: (String) async -> String?
    let onCancel: () -> Void

    @State private var digits = ""
    @State private var error: String?
    @State private var busy = false
    /// A wrong PIN: the dots shake.
    @State private var shakes = 0

    private let pinLength = 4

    var body: some View {
        ZStack {
            if background { ATVBackground() }
            VStack(spacing: CueSpacing.xl) {
                Text(title)
                    .font(.system(size: 57, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
                }

                HStack(spacing: CueSpacing.lg) {
                    ForEach(0..<pinLength, id: \.self) { i in
                        Circle()
                            .fill(Color.white.opacity(i < digits.count ? FixedFocusText.primary : 0.2))
                            .frame(width: 28, height: 28)
                    }
                }
                .modifier(Shake(shakes: CGFloat(shakes)))
                .animation(.linear(duration: 0.4), value: shakes)
                .padding(.vertical, CueSpacing.md)

                // Its room kept: the keys don't move as it comes and goes.
                Text(error ?? " ")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))

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
                shakes += 1
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
            .scaleEffect(isFocused ? ProfileGate.focusScale : 1)
            .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
            .cardPressDip(configuration.isPressed)
    }
}

/// Side to side, three times, settling (`shakes` counts the wrong PINs).
private struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = shakes - shakes.rounded(.down)
        let x = 14 * sin(progress * .pi * 6) * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

// MARK: - Add Profile, guided

/// Adding a profile, a step at a time (a setup assistant): its name (the
/// keyboard), an avatar, where its titles come from (Primary's add-ons or
/// none), a PIN or not (signed in to Nuvio only), then the new profile with
/// "You're all set". Created only at the last press; Back goes a step
/// back, from the first out. On the gate it's the curtain's background
/// (`background` false); from Settings, a cover of its own.
struct ProfileSetup: View {
    @EnvironmentObject private var profiles: ProfileStore
    var background = true
    /// The last step's button ("Start Watching" on the gate).
    var finishTitle = "Done"
    let onFinish: (UserProfile) -> Void
    let onCancel: () -> Void

    private enum Step: Int, CaseIterable { case name, avatar, addons, pin, done }

    @State private var step = Step.name
    @State private var name = ""
    @State private var avatarID: String?
    @State private var usesPrimary = true
    @State private var pin: String?
    @State private var pinEntry: PinEntry?
    @State private var keyboard: KeyboardRequest?
    @State private var creating = false
    @FocusState private var focused: String?

    private enum PinEntry: Identifiable {
        case first, again(String)
        var id: String { if case .again = self { return "again" }; return "first" }
    }

    /// Steps shown (no PIN while signed out: Nuvio keeps PINs).
    private var steps: [Step] { Step.allCases.filter { $0 != .pin || profiles.accountAvailable } }

    var body: some View {
        ZStack {
            if background { ATVBackground() }
            if let entry = pinEntry {
                pinPad(entry)
                    .id(entry.id)
                    .transition(.opacity)
            } else if step == .avatar {
                avatarPage
                    .transition(.opacity)
            } else {
                page
                    .id(step)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: step)
        .animation(Motion.fade, value: pinEntry?.id)
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        .onAppear { askName() }
    }

    @ViewBuilder
    private var page: some View {
        VStack(spacing: 56) {
            switch step {
            case .name:
                // The keyboard is the step; this shows while it opens.
                heading("What's your name?", nil)
            case .avatar:
                EmptyView()   // `avatarPage`
            case .addons:
                heading("Where should titles come from?", name)
                VStack(spacing: 20) {
                    SetupChoice(title: "Use Primary's Add-ons",
                                detail: "The same catalogs and sources as \(profiles.profiles.first?.name ?? "Primary").") {
                        usesPrimary = true; advance()
                    }
                    .focused($focused, equals: "primary")
                    SetupChoice(title: "Start Empty", detail: "Add its own add-ons later in Settings.") {
                        usesPrimary = false; advance()
                    }
                    .focused($focused, equals: "empty")
                }
                .defaultFocus($focused, usesPrimary ? "primary" : "empty")
            case .pin:
                heading("Lock this profile?", "A 4-digit PIN before \(name) opens.")
                VStack(spacing: 20) {
                    SetupChoice(title: "Not Now", detail: "You can set one later in Settings.") {
                        pin = nil; advance()
                    }
                    .focused($focused, equals: "nopin")
                    SetupChoice(title: "Set a PIN", detail: nil) { pinEntry = .first }
                        .focused($focused, equals: "pin")
                }
                .defaultFocus($focused, "nopin")
            case .done:
                ProfileAvatarView(profile: preview, size: ProfileGate.avatarSize)
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 2) }
                heading("You're all set, \(name)", nil)
                SetupChoice(title: finishTitle, detail: nil, width: 420) { finish() }
                    .disabled(creating)
            }
            dots
        }
        .padding(.horizontal, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { back() }
    }

    private func heading(_ title: String, _ subtitle: String?) -> some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 57, weight: .semibold))
                .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
            }
        }
        .multilineTextAlignment(.center)
    }

    /// Where you are: a dot per step, the current one bright.
    private var dots: some View {
        HStack(spacing: 14) {
            ForEach(steps, id: \.self) { s in
                Circle()
                    .fill(Color.white.opacity(s == step ? FixedFocusText.primary : 0.2))
                    .frame(width: 12, height: 12)
            }
        }
    }

    /// The avatar: Settings' avatar page in its column (`AvatarChoices`),
    /// the rows scrolling under the heading; the dots at the screen's foot.
    private var avatarPage: some View {
        ZStack(alignment: .bottom) {
            SettingsPage(title: "Pick an avatar", subtitle: "For \(name). Initials use the profile's colour.") {
                AvatarChoices(initials: initialsPreview, chosen: avatarID) { id in
                    avatarID = id
                    advance()
                }
            }
            .environment(\.settingsRowFocus, $focused)
            .defaultFocus($focused, avatarID ?? "initials")
            .frame(width: SettingsMetrics.columnWidth)
            // The rows end above the dots, fading out on their way to them
            // (they ran under the dots).
            .padding(.bottom, 130)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 50)
                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, -60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            dots
                .padding(.bottom, 48)
        }
        .ignoresSafeArea()
        .onExitCommand { back() }
    }

    private func pinPad(_ entry: PinEntry) -> some View {
        switch entry {
        case .first:
            return PinEntryView(title: "Choose a 4-digit PIN", subtitle: name, background: false,
                                onSubmit: { value in pinEntry = .again(value); return nil },
                                onCancel: { pinEntry = nil })
        case .again(let first):
            return PinEntryView(title: "Enter it again", subtitle: name, background: false,
                                onSubmit: { value in
                                    guard value == first else { return "The PINs didn't match." }
                                    pin = value
                                    pinEntry = nil
                                    advance()
                                    return nil
                                },
                                onCancel: { pinEntry = .first })
        }
    }

    /// The colour `addProfile` will give it (the first free slot's).
    private var nextColor: String {
        let used = Set(profiles.profiles.map(\.id))
        let id = (1...ProfileStore.maxProfiles).first { !used.contains($0) } ?? 1
        return ProfileStore.avatarColors[(id - 1) % ProfileStore.avatarColors.count]
    }

    private var initialsPreview: UserProfile {
        UserProfile(id: -1, name: name, avatarColorHex: nextColor)
    }

    private var preview: UserProfile {
        UserProfile(id: -1, name: name, avatarColorHex: nextColor, avatarID: avatarID)
    }

    private func askName() {
        keyboard = KeyboardRequest(text: name, placeholder: "Profile name") { text in
            let text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { onCancel(); return }
            name = text
            step = .avatar
        }
    }

    private func advance() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        step = steps[i + 1]
    }

    private func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { onCancel(); return }
        step = steps[i - 1]
        if step == .name { askName() }
    }

    private func finish() {
        guard !creating else { return }
        creating = true
        guard let created = profiles.addProfile(name: name) else {
            ToastCenter.shared.show("Can't add a profile just yet — try again in a moment",
                                    icon: "person.crop.circle.badge.exclamationmark")
            creating = false
            return
        }
        if let avatarID { profiles.setAvatar(id: created.id, avatarID: avatarID) }
        if usesPrimary { profiles.setUsesPrimaryAddons(id: created.id, true) }
        let profile = profiles.profiles.first { $0.id == created.id } ?? created
        guard let pin else { onFinish(profile); return }
        Task {
            if case .failure(let message) = await profiles.setPin(id: created.id, pin: pin, currentPin: nil) {
                ToastCenter.shared.show("PIN not set — \(message)", icon: "lock.slash")
            }
            onFinish(profiles.profiles.first { $0.id == created.id } ?? profile)
        }
    }
}

/// A step's choice: a wide flat capsule (focused white, dark text), what it
/// means under it.
private struct SetupChoice: View {
    let title: String
    let detail: String?
    var width: CGFloat = 760
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(title: title, detail: detail, width: width) }
            .buttonStyle(GateTileStyle())
    }

    private struct Face: View {
        @Environment(\.isFocused) private var isFocused
        let title: String
        let detail: String?
        let width: CGFloat

        var body: some View {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 32, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 24))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(isFocused ? FlatControl.contentOnFocus : FlatControl.content)
            .padding(.vertical, detail == nil ? 22 : 18)
            .frame(width: width)
            .background(Capsule().fill(isFocused ? FlatControl.focus : FlatControl.rest))
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
            .scaleEffect(isFocused ? ProfileGate.focusScale : 1)
            .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
        }
    }
}
