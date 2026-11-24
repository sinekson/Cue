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
/// its PIN) and adding one — Add Profile last, below 5 (`UINewProfilePage`, one
/// guided steps, ending in the new profile picked). Editing: holding an
/// avatar opens that profile's Settings page over the gate (a locked one
/// asks its PIN first; nothing switches). The picked avatar flies to the top bar's as Home dissolves in;
/// Home not ready yet for that profile (the launch's preload, or another
/// profile's after a switch — `LaunchPreloader.picked`), it waits in the
/// middle over the launch's status line. At launch and coming back, the
/// focused profile is picked by itself after `autoPick` with no press (not
/// a locked one), "Continuing as …" under the names for its last
/// `autoPickNotice`; any press stops it for good.
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
    /// No press this long: the focused profile is picked.
    static let autoPick: Double = 5
    /// "Continuing as …" for the auto-pick's last seconds.
    static let autoPickNotice: Double = 2
    /// The status line's baseline room under the waiting avatar.
    static let statusGap: CGFloat = 64

    private enum Phase { case choosing, waiting, flying }
    @State private var phase = Phase.choosing
    @State private var picked: UserProfile?
    @State private var pinProfile: UserProfile?
    /// Each avatar's centre on the screen — where the picked one sets off.
    @State private var centres: [Int: CGPoint] = [:]
    @State private var flyerCentre = CGPoint.zero
    @State private var flyerScale: CGFloat = 1
    /// The status line up under the waiting avatar (once it's in the middle).
    @State private var statusUp = false
    /// The profile about to be picked by itself ("Continuing as …").
    @State private var continuing: UserProfile?
    /// A press or a focus move: no auto-pick any more.
    @State private var touched = false
    @State private var screen = CGSize.zero
    @State private var adding = false
    /// The PIN asked to edit a profile (held), not to pick it.
    @State private var pinToEdit = false
    /// A held profile's Settings page over the gate (by id).
    @State private var editing: Int?
    /// Opened from its pencil: Back lands there again (else on the avatar).
    @State private var editFromPencil = false
    @FocusState private var focused: Int?
    /// Add Profile's focus id (profiles count up from 1; their pencils
    /// below 0, `pencilID`).
    private static let addID = 0
    private static func pencilID(_ id: Int) -> Int { -id }

    var body: some View {
        ZStack {
            if let id = editing {
                ProfileGateEditor(mode: .edit(id)) {
                    editing = nil
                    // Back where it was opened: its pencil, else the avatar
                    // (deleted: the active one).
                    let kept = profiles.profiles.contains { $0.id == id }
                    let back = !kept ? profiles.activeProfileID : editFromPencil ? Self.pencilID(id) : id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = back }
                }
                .ignoresSafeArea()
                .background(ATVBackground())
                .transition(.opacity)
            } else if adding {
                ProfileGateEditor(mode: .create { created in
                    adding = false
                    choose(created, from: CGPoint(x: screen.width / 2, y: screen.height / 2))
                }) {
                    adding = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = Self.addID }
                }
                .ignoresSafeArea()
                .background(ATVBackground())
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
                        let back = pinToEdit && editFromPencil ? Self.pencilID(locked.id) : locked.id
                        pinToEdit = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = back }
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
            if phase == .waiting, statusUp {
                SweepLine(text: launch.status, sweeping: true)
                    .frame(width: 1200, height: 44)
                    .position(x: screen.width / 2,
                              y: screen.height / 2 + Self.avatarSize / 2 + Self.statusGap)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
        .animation(Motion.fade, value: pinProfile?.id)
        .animation(Motion.fade, value: adding)
        .animation(Motion.fade, value: editing)
        .animation(Motion.fade, value: phase == .waiting && statusUp)
        // At launch and coming back there's nothing to go back to (the
        // window drops it — `BackCatch`); from the top bar, Back closes it.
        .onExitCommand {
            if editing != nil || adding { NotificationCenter.default.post(name: .gateEditorBack, object: nil) }
            else if phase == .choosing, !adding { launch.cancelGate() }
        }
        .onChange(of: launch.ready) { _, ready in if ready, phase == .waiting { fly() } }
        .onAppear {
            // Over a page that just lost its focus (the top bar's avatar):
            // asked, once the gate is there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = profiles.activeProfileID }
        }
        .task { await profiles.loadAvatarCatalog() }
        .task { await autoPickAfterRest() }
        .onChange(of: focused) { old, _ in if old != nil { stopAutoPick() } }
    }

    /// The focused profile picked by itself after `autoPick` with no press
    /// (at launch and coming back; not from the top bar, not a locked one).
    private func autoPickAfterRest() async {
        guard mode != .topBar else { return }
        let appeared = CACurrentMediaTime()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if InputHold.lastPress > appeared { stopAutoPick() }
            // Picked (by a press or by itself): nothing left to wait for.
            if phase != .choosing { return }
            guard !touched, phase == .choosing, !adding, pinProfile == nil, editing == nil,
                  let id = focused, let profile = profiles.profiles.first(where: { $0.id == id }),
                  !profile.pinEnabled else {
                if touched { return }
                continue
            }
            let rested = CACurrentMediaTime() - appeared
            if rested >= Self.autoPick {
                continuing = nil
                select(profile)
                return
            }
            if rested >= Self.autoPick - Self.autoPickNotice, continuing == nil { continuing = profile }
        }
    }

    private func stopAutoPick() {
        touched = true
        continuing = nil
    }

    private var chooser: some View {
        VStack(spacing: 72) {
            Text("Who's watching?")
                .font(.system(size: 57, weight: .semibold))
                .foregroundStyle(CueInk.primary)
            HStack(alignment: .top, spacing: 40) {
                ForEach(profiles.profiles) { profile in
                    let pencil = Self.pencilID(profile.id)
                    VStack(spacing: GatePencil.gap) {
                        Button { select(profile) } label: {
                            GateTile(profile: profile, size: Self.avatarSize,
                                     away: picked?.id == profile.id) { centre in
                                centres[profile.id] = centre
                            }
                        }
                        .buttonStyle(GateTileStyle())
                        .focused($focused, equals: profile.id)
                        // Held: its Settings page (a shortcut for the pencil).
                        .holdMenu(focused: focused == profile.id, direct: true) {
                            [MenuEntry(title: "Edit Profile", icon: "gearshape") { edit(profile) }]
                        }
                        // Its pencil, under the focused avatar only (Netflix's):
                        // Down reaches it, Left/Right along the pencils; from
                        // anywhere else none can take focus.
                        Button { edit(profile, fromPencil: true) } label: {
                            GatePencil(shown: phase == .choosing && (focused == profile.id || focused == pencil))
                        }
                        .buttonStyle(GateTileStyle())
                        .focused($focused, equals: pencil)
                        .disabled(!(focused == profile.id || (focused ?? 0) < 0))
                        .accessibilityLabel("Edit \(profile.name)")
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
            // Room kept, so nothing moves as it shows.
            Text("Continuing as \(continuing?.name ?? " ")")
                .font(.system(size: 24))
                .foregroundStyle(CueInk.tertiary)
                .opacity(continuing == nil ? 0 : 1)
                .animation(Motion.fade, value: continuing == nil)
                .padding(.top, -24)
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
            .scaleEffect(flyerScale)
            .position(flyerCentre)
            .allowsHitTesting(false)
    }

    /// A profile's page over the gate — a locked one's PIN first.
    private func edit(_ profile: UserProfile, fromPencil: Bool = false) {
        editFromPencil = fromPencil
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
            if phase == .waiting { statusUp = true }
        }
    }

    /// Up into the top bar's avatar, Home dissolving in under it.
    private func fly() {
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
    let onCentre: (CGPoint) -> Void

    var body: some View {
        VStack(spacing: GateSlot.nameGap) {
            ZStack(alignment: .bottomTrailing) {
                GateAvatarFace(profile: profile, size: size, lit: isFocused)
                if profile.pinEnabled {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(CueInk.primary)
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
            Text(profile.name)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(CueInk.color(isFocused ? FixedFocusText.primary : FixedFocusText.secondary))
                .lineLimit(1)
            // Out of the grown avatar's way: by its growth below it.
            .offset(y: isFocused ? GateSlot.step(size) : 0)
            .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
        }
        .frame(width: size + GateSlot.sideRoom)
    }
}

/// A profile's pencil under its name: a flat round plate (Add Profile's
/// look, smaller), focused white with a dark pencil, grown as the avatars.
/// Its room always kept; only its face hides (a hidden view can't take
/// focus, and Left/Right go along the pencils).
private struct GatePencil: View {
    @Environment(\.isFocused) private var isFocused
    let shown: Bool
    static let size: CGFloat = 60
    /// Under the name.
    static let gap: CGFloat = 20

    var body: some View {
        Circle()
            .fill(isFocused ? FlatControl.focus : FlatControl.rest)
            .overlay {
                Image(systemName: "pencil")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? FlatControl.contentOnFocus : FlatControl.content)
            }
            .frame(width: Self.size, height: Self.size)
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 12, y: 6)
            .scaleEffect(isFocused ? 1.1 : 1)
            .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
            .opacity(shown || isFocused ? 1 : 0)
            .animation(Motion.fade, value: shown)
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
                .foregroundStyle(CueInk.color(isFocused ? FixedFocusText.primary : FixedFocusText.secondary))
                .lineLimit(1)
                .offset(y: isFocused ? GateSlot.step(size) : 0)
                .animation(isFocused ? DetailActionButton.open : DetailActionButton.leave, value: isFocused)
        }
        .frame(width: size + GateSlot.sideRoom)
    }
}

extension Notification.Name {
    /// Back over the gate's profile editor (SwiftUI's exit handler gets it first).
    static let gateEditorBack = Notification.Name("cue.gateEditorBack")
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
                    .foregroundStyle(CueInk.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(CueInk.secondary)
                }

                HStack(spacing: CueSpacing.lg) {
                    ForEach(0..<pinLength, id: \.self) { i in
                        Circle()
                            .fill(CueInk.color(i < digits.count ? FixedFocusText.primary : 0.2))
                            .frame(width: 28, height: 28)
                    }
                }
                .modifier(Shake(shakes: CGFloat(shakes)))
                .animation(.linear(duration: 0.4), value: shakes)
                .padding(.vertical, CueSpacing.md)

                // Its room kept: the keys don't move as it comes and goes.
                Text(error ?? " ")
                    .font(.system(size: 24))
                    .foregroundStyle(CueInk.secondary)

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
