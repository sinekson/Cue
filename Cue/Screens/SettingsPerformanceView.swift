import SwiftUI

/// Settings → Developer, second half: per-effect switches so slower Apple TVs (HD,
/// 4K 1st gen) can turn off exactly the things causing lag — each row says
/// what the effect costs and what OFF looks like. All ON = the full look.
struct PerformanceSettings: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var playerStore: PlayerSettingsStore
    @ObservedObject private var store = PerformanceSettingsStore.shared

    private var s: Binding<PerformanceSettingsStore.Settings> {
        Binding(get: { store.settings }, set: { store.settings = $0 })
    }

    /// Master switch: ON = every effect off (lightest), OFF = full look.
    private var maxPerformance: Binding<Bool> {
        Binding(get: { store.isMaxPerformance }, set: { store.setMaxPerformance($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.xl) {

            if store.reduceMotion { reduceMotionBanner }

            SettingsGroupCard(
                title: "Quick setup",
                subtitle: "One-tap tuning for this Apple TV"
            ) {
                PerfToggleRow(
                    icon: "bolt.fill",
                    title: "Performance mode",
                    subtitle: "Turns every visual effect below OFF at once for the smoothest, lightest experience — best on older Apple TVs. Turn it off to restore the full look. You can still fine-tune individual effects afterward.",
                    isOn: maxPerformance
                )
                PerfActionRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset to recommended",
                    subtitle: "Restore the tuned defaults for \(PerformanceProfile.tierLabel).",
                    action: { store.resetToRecommended() }
                )
            }

            SettingsGroupCard(
                title: "Home billboard",
                subtitle: "The hero area at the top of the Home screen"
            ) {
                PerfToggleRow(
                    icon: "photo.tv",
                    title: "Hero backdrop artwork",
                    subtitle: "Full-screen art behind Home that changes with every card you focus — the single heaviest effect on older Apple TVs. Off: flat background; the title, info and rows are unchanged.",
                    isOn: s.heroBackdrop
                )
                PerfToggleRow(
                    icon: "square.stack.3d.forward.dottedline",
                    title: "Hero crossfade",
                    subtitle: "Dissolve when the hero art and info change: blends two full-screen images and rebuilds the title/synopsis panel on every card you focus. The main reason browsing rows feels heavier on Modern than on the other layouts. Off: art and text switch instantly — much lighter, recommended on older Apple TVs.",
                    isOn: s.heroCrossfade
                )
            }

            SettingsGroupCard(
                title: "Cards & rows",
                subtitle: "Posters and the rows they live in"
            ) {
                PerfToggleRow(
                    icon: "rectangle.fill.on.rectangle.fill",
                    title: "Card shadows",
                    subtitle: "Soft drop shadows under posters and behind a focused card. Each is an offscreen blur that re-renders on every focus move — the biggest scroll cost on older boxes. Off: flat cards with just the focus border, same layout.",
                    isOn: s.cardShadows
                )
                PerfToggleRow(
                    icon: "arrow.up.left.and.arrow.down.right",
                    title: "Focus zoom",
                    subtitle: "The focused card springs slightly larger. Off: only the highlight ring marks focus — the cheapest possible focus effect.",
                    isOn: s.focusZoom
                )
                PerfToggleRow(
                    icon: "move.3d",
                    title: "Card wiggle & lift",
                    subtitle: "The native Apple TV card effect: the focused poster raises and tilts/parallaxes as you move on the trackpad, like a Home-screen icon. The system re-composites the whole focused card as your finger moves — the heaviest per-frame focus cost, and rough on older Apple TVs. Off: cards do a light scale on focus instead, no tilt.",
                    isOn: s.cardParallax
                )
            }

            SettingsGroupCard(
                title: "Animations",
                subtitle: "Motion across the app's chrome"
            ) {
                PerfToggleRow(
                    icon: "sidebar.left",
                    title: "Sidebar animation",
                    subtitle: "The sidebar's expand/collapse spring and the dim it casts over the content — a full-screen fade composited on every open/close. Off: the sidebar and dim appear/disappear instantly.",
                    isOn: s.sidebarAnimation
                )
                PerfToggleRow(
                    icon: "hand.tap",
                    title: "Button & pill effects",
                    subtitle: "Small controls (See All, tab pills, filter chips, button presses) scale and spring when focused or clicked. Off: they highlight instantly with no motion.",
                    isOn: s.buttonAnimations
                )
            }

            SettingsGroupCard(
                title: "Artwork loading",
                subtitle: "How poster images arrive on screen"
            ) {
                PerfToggleRow(
                    icon: "square.and.arrow.down.on.square",
                    title: "Preload row artwork",
                    subtitle: "Downloads posters for rows below the fold in the background so they're ready when you scroll. Off: less background work while browsing, but posters load as they appear.",
                    isOn: s.artworkPrefetch
                )
                PerfToggleRow(
                    icon: "circle.lefthalf.filled",
                    title: "Artwork fade-in",
                    subtitle: "Posters fade in when they finish loading; each fade re-renders its card for the duration. Off: artwork pops in instantly.",
                    isOn: s.artworkFadeIn
                )
            }

            SettingsGroupCard(
                title: "Collections",
                subtitle: "Focus artwork on collection folder tiles"
            ) {
                CueDropdown(
                    title: "Collection focus artwork",
                    subtitle: store.settings.collectionGifQuality.summary,
                    icon: "sparkles.tv",
                    selection: store.settings.collectionGifQuality.rawValue,
                    options: CollectionGifQuality.allCases.map {
                        CueDropdownOption($0.rawValue, $0.displayName)
                    }
                ) { raw in
                    store.settings.collectionGifQuality =
                        CollectionGifQuality(rawValue: raw) ?? .deviceDefault
                }
            }

            SettingsGroupCard(
                title: "Developer",
                subtitle: "Diagnostics — safe to leave off"
            ) {

                PerfToggleRow(
                    icon: "hand.tap",
                    title: "Hold menu probe",
                    subtitle: "Trace hold-Select on screen: whether a card takes focus, whether the press reaches the app, whether a long press is recognised, and whether tvOS actually builds the menu. For diagnosing hold menus that do nothing.",
                    isOn: s.showHoldProbe
                )

                PerfToggleRow(
                    icon: "waveform.path.ecg",
                    title: "Playback diagnostics HUD",
                    subtitle: "Live engine, fps, dropped frames, A/V drift, bitrate and buffer depth over the video. For chasing stutter on this box.",
                    isOn: s.showPlayerDiagnostics
                )

                // Lived under Playback → Seeking; it's a diagnostic overlay, so
                // it belongs with the other two.
                PerfToggleRow(
                    icon: "photo.stack",
                    title: "Scrub preview frames",
                    subtitle: "Decode a frame every 30s so the progress bar can show the scene you're seeking to. Costs a second connection and decoder alongside playback — turn off if a stream stutters.",
                    isOn: Binding(get: { playerStore.settings.scrubPreviewsEnabled },
                                  set: { playerStore.settings.scrubPreviewsEnabled = $0 })
                )
                PerfToggleRow(
                    icon: "ladybug.fill",
                    title: "Show input debug",
                    subtitle: "Overlay the last trackpad/remote event in the player, for tuning gestures on a real Apple TV.",
                    isOn: Binding(get: { playerStore.settings.showInputDebug },
                                  set: { playerStore.settings.showInputDebug = $0 })
                )

                // The one switch that makes everything else diagnosable on a
                // Release/sideloaded build. Turn it on, reproduce the problem,
                // then pull the log with scripts/record.sh (or probe.sh).
                PerfToggleRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Capture diagnostics (LAN log server)",
                    subtitle: "Record app and playback events (navigation, buffering, stalls, seeks, source picks, errors, memory) and serve a live plain-text log at http://<this Apple TV's IP>:8123. Use scripts/record.sh <ip> to save a session. Off by default; costs a little CPU while on.",
                    isOn: Binding(
                        get: { ProbeGate.isEnabled },
                        set: { on in
                            UserDefaults.standard.set(on, forKey: ProbeGate.defaultsKey)
                            ProbeGate.set(on)
                            if on { ColorProbeServer.shared.start() }
                            else { ColorProbeServer.shared.stop() }
                        }
                    )
                )
            }

            Text("Everything ON is the app's full look. Turn things OFF top-to-bottom until the Home screen feels right — each switch only removes visual polish, never content or features. These switches are per-device and don't sync to your account.")
                .font(.system(size: 18))
                .foregroundStyle(theme.palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shown when the system Accessibility → Reduce Motion switch is on: the
    /// motion effects are forced off no matter what the switches below say.
    private var reduceMotionBanner: some View {
        HStack(spacing: CueSpacing.md) {
            SettingsIconTile(symbol: "figure.walk.motion")
            VStack(alignment: .leading, spacing: 4) {
                Text("Reduce Motion is on")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Your system Accessibility setting is disabling the motion effects (card wiggle & lift, hero crossfade, focus zoom, sidebar and button animations, artwork fade-in) regardless of the switches below.")
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(CueSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: theme.settingsCardRadius, style: .continuous)
                .fill(theme.palette.secondary.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsCardRadius, style: .continuous)
                .strokeBorder(theme.palette.secondary.opacity(0.4), lineWidth: 1)
        )
    }
}

/// Toggle row matching the redesigned settings rows (icon tile, title, wrapped
/// description, switch; flat until focused).
private struct PerfToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            PerfRowLabel(icon: icon, title: title, subtitle: subtitle) {
                CueSwitch(isOn: isOn)
            }
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

/// A tappable action row (no switch) — used for "Reset to recommended".
private struct PerfActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PerfRowLabel(icon: icon, title: title, subtitle: subtitle) {
                EmptyView()
            }
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

/// Shared row body: accent icon tile + title + wrapped description + a trailing
/// accessory (switch, or nothing). Flat until focused, matching the other
/// redesigned settings panes.
private struct PerfRowLabel<Accessory: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: CueSpacing.md) {
            SettingsIconTile(symbol: icon)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 1000, alignment: .leading)
            }
            Spacer(minLength: CueSpacing.lg)
            accessory
                .padding(.top, 4)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, CueSpacing.md)
        .frame(minHeight: 76)
        .frame(maxWidth: .infinity)
        .background(SettingsRowBackground(isFocused: isFocused))
    }
}


/// Settings → Developer, first half (Render Lab): the FPS overlay and the
/// render bisect switches in one place, for quick A/B runs while tuning.
struct RenderLabSettings: View {
    @ObservedObject private var store = PerformanceSettingsStore.shared
    @ObservedObject private var probe = RenderProbe.shared

    private var s: Binding<PerformanceSettingsStore.Settings> {
        Binding(get: { store.settings }, set: { store.settings = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.xl) {
            SettingsGroupCard(title: "Home layout", subtitle: "Switch tabs to refresh Home.") {
                PerfToggleRow(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "Launch: show numbers",
                    subtitle: "The launch screen lists what it loaded and how long each step took (cold starts).",
                    isOn: Binding(get: { probe.flags.launchNumbers }, set: { probe.flags.launchNumbers = $0 })
                )
                CueDropdown(
                    title: "Billboard change",
                    subtitle: "Left / Right on the billboard: text and picture drift together — or depth + cascade: the text further, the picture less, the text's parts one after another (logo, chips, facts, tagline) — or a real scroll: the whole page slides out as the next slides in.",
                    icon: "square.stack.3d.forward.dottedline",
                    selection: probe.flags.billboardChange,
                    options: [("drift", "Drift"), ("depthCascade", "Depth + cascade"), ("scroll", "Scroll")]
                        .map { CueDropdownOption($0.0, $0.1) }
                ) { raw in
                    probe.flags.billboardChange = raw
                }
                PerfToggleRow(
                    icon: "plus.magnifyingglass",
                    title: "Billboard: slow zoom",
                    subtitle: "Each billboard picture zooms in very slowly (to 104 %) while it shows — it never looks frozen.",
                    isOn: Binding(get: { probe.flags.billboardSlowZoom }, set: { probe.flags.billboardSlowZoom = $0 })
                )
                CueDropdown(
                    title: "Billboard scrim",
                    subtitle: "What darkens the billboard's artwork behind the text: the whole left and bottom, or only around the text — in black or in the title's own colour.",
                    icon: "text.below.photo",
                    selection: probe.flags.billboardScrim,
                    options: FixedFocusBillboardScrim.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.billboardScrim = raw
                }
                CueDropdown(
                    title: "Billboard chips",
                    subtitle: "Billboard and Details: the status badge and ratings right under the logo, or last, under the tagline.",
                    icon: "rectangle.stack",
                    selection: probe.flags.billboardChips,
                    options: [("first", "Under the logo"), ("last", "Under the tagline")]
                        .map { CueDropdownOption($0.0, $0.1) }
                ) { raw in
                    probe.flags.billboardChips = raw
                }
                CueDropdown(
                    title: "Details: blurred picture, brightness cap",
                    subtitle: "Below the billboard: the blurred picture no brighter than this — its bright parts pulled down softly, dark parts untouched, so text reads on any picture (it replaces the picture dim below while on). Applies to the next title.",
                    icon: "sun.max.trianglebadge.exclamationmark",
                    selection: String(probe.flags.detailsBlurCap),
                    options: [(0.0, "Off"), (0.55, "55 %"), (0.45, "45 %"), (0.35, "35 %"), (0.25, "25 %")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.detailsBlurCap = v }
                }
                PerfToggleRow(
                    icon: "paintpalette",
                    title: "Poster rims",
                    subtitle: "Each poster gets a subtle rim in its own colour (pre-rendered; switch tabs to refresh).",
                    isOn: Binding(get: { probe.flags.posterRims }, set: { probe.flags.posterRims = $0 })
                )
                CueDropdown(
                    title: "Rim",
                    subtitle: "Posters' and box's rim: a colour of its own, or glass-like — lighter over the poster's own edge (switch tabs to refresh).",
                    icon: "square.dashed",
                    selection: probe.flags.rimStyle,
                    options: FixedFocusRim.Style.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.rimStyle = raw
                }
                PerfToggleRow(
                    icon: "rectangle.dashed",
                    title: "Box outline: rim",
                    subtitle: "The box's outline as a rim (see Rim). Off: plain white.",
                    isOn: Binding(get: { probe.flags.boxRimColored }, set: { probe.flags.boxRimColored = $0 })
                )
                PerfToggleRow(
                    icon: "circle.lefthalf.filled.righthalf.striped.horizontal",
                    title: "Background tint",
                    subtitle: "The background takes the focused title's colour, strongest around the box.",
                    isOn: Binding(get: { probe.flags.backgroundTint }, set: { probe.flags.backgroundTint = $0 })
                )
                CueDropdown(
                    title: "Background",
                    subtitle: "A fixed, dark colour with a soft glow — or the focused title's colour (with a dark left third and foot).",
                    icon: "photo.on.rectangle",
                    selection: probe.flags.backgroundStyle,
                    options: FixedFocusBackground.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.backgroundStyle = raw
                }
                CueDropdown(
                    title: "Tint delay",
                    subtitle: "Title colour: how long you rest on a title before the background changes.",
                    icon: "timer",
                    selection: String(probe.flags.tintDelay),
                    options: [0.0, 0.02, 0.04, 0.06, 0.08, 0.12, 0.18, 0.25].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintDelay = v }
                }
                CueDropdown(
                    title: "Tint fade",
                    subtitle: "Title colour: how long the change of colour takes.",
                    icon: "circle.lefthalf.filled",
                    selection: String(probe.flags.tintFade),
                    options: [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.6].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintFade = v }
                }
                PerfToggleRow(
                    icon: "arrow.left.and.right.circle",
                    title: "Tint: move with focus",
                    subtitle: "The background's colours change on the same press as the focus, on the same curve and in the same time (Motion: Left / Right), the next cards' colours ready beforehand. Off: after the tint delay, over the tint fade.",
                    isOn: Binding(get: { probe.flags.tintFollowsFocus }, set: { probe.flags.tintFollowsFocus = $0 })
                )
                PerfToggleRow(
                    icon: "hare",
                    title: "Tint: calm while scrolling fast",
                    subtitle: "With move with focus: presses in quick succession are a burst — the colours change only now and then, over a calm blend, skipping the cards you pass; on landing, the focus spring again.",
                    isOn: Binding(get: { probe.flags.tintBurstCalm }, set: { probe.flags.tintBurstCalm = $0 })
                )
                CueDropdown(
                    title: "Tint burst: press gap",
                    subtitle: "Presses closer together than this count as fast scrolling.",
                    icon: "timer",
                    selection: String(probe.flags.tintBurstGap),
                    options: [0.2, 0.25, 0.3, 0.4, 0.5].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintBurstGap = v }
                }
                CueDropdown(
                    title: "Tint burst: change every",
                    subtitle: "While scrolling fast: at most one colour change this often.",
                    icon: "metronome",
                    selection: String(probe.flags.tintBurstEvery),
                    options: [0.2, 0.3, 0.4, 0.6, 0.8].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintBurstEvery = v }
                }
                CueDropdown(
                    title: "Tint burst: blend",
                    subtitle: "While scrolling fast: how long each colour change blends (ease-in-out).",
                    icon: "wave.3.right",
                    selection: String(probe.flags.tintBurstBlend),
                    options: [0.3, 0.4, 0.5, 0.7, 1.0].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintBurstBlend = v }
                }
                CueDropdown(
                    title: "Tint strength",
                    subtitle: "Title colour: how strongly the colour covers the background.",
                    icon: "drop.fill",
                    selection: String(probe.flags.tintStrength),
                    options: [0.3, 0.4, 0.5, 0.6, 0.7, 0.85, 1.0].map { CueDropdownOption(String($0), "\(Int(($0 * 100).rounded())) %") }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintStrength = v }
                }
                CueDropdown(
                    title: "Tint colour",
                    subtitle: "Title colour: the artwork's average colour, its dominant colour, or its two strongest colours blended across the screen.",
                    icon: "eyedropper",
                    selection: probe.flags.tintMode,
                    options: FixedFocusTint.Mode.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.tintMode = raw
                }
                CueDropdown(
                    title: "Colour layout: grid",
                    subtitle: "Picture's colour layout: how many parts of the picture give their own colour — more: closer to the picture.",
                    icon: "square.grid.3x3",
                    selection: probe.flags.layoutGrid,
                    options: [("2x2", "2 × 2"), ("3x3", "3 × 3"), ("4x3", "4 × 3"), ("5x3", "5 × 3")]
                        .map { CueDropdownOption($0.0, $0.1) }
                ) { raw in
                    probe.flags.layoutGrid = raw
                }
                CueDropdown(
                    title: "Colour layout: saturation",
                    subtitle: "Picture's colour layout: how full the colours are.",
                    icon: "drop",
                    selection: String(probe.flags.layoutSaturation),
                    options: [(1.0, "× 1.0"), (1.1, "× 1.1"), (1.25, "× 1.25"), (1.4, "× 1.4")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.layoutSaturation = v }
                }
                CueDropdown(
                    title: "Colour layout: light and dark",
                    subtitle: "Picture's colour layout: how much of the picture's own light and dark parts is kept. Off: every part equally bright.",
                    icon: "circle.righthalf.filled",
                    selection: String(probe.flags.layoutLightness),
                    options: [(0.0, "Off"), (0.25, "25 %"), (0.5, "50 %"), (0.75, "75 %")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.layoutLightness = v }
                }
                PerfToggleRow(
                    icon: "circle.lefthalf.filled",
                    title: "Tint: always two colours",
                    subtitle: "Two colours: always a second one — another colour of the picture, else the neighbouring one, else one made from the main colour. Off: only when the picture clearly has a second colour.",
                    isOn: Binding(get: { probe.flags.tintAlwaysTwo }, set: { probe.flags.tintAlwaysTwo = $0 })
                )
                CueDropdown(
                    title: "Tint brightness",
                    subtitle: "Title colour: how bright the colour is before it is laid over the dark base.",
                    icon: "sun.min",
                    selection: String(probe.flags.tintBrightness),
                    options: [0.45, 0.55, 0.65, 0.75, 0.85, 1.0].map { CueDropdownOption(String($0), "\(Int(($0 * 100).rounded())) %") }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintBrightness = v }
                }
                PerfToggleRow(
                    icon: "flame",
                    title: "Tint: brighter warm colours",
                    subtitle: "Yellow and orange get extra brightness, so they read as gold instead of brown.",
                    isOn: Binding(get: { probe.flags.tintWarmBoost }, set: { probe.flags.tintWarmBoost = $0 })
                )
                PerfToggleRow(
                    icon: "shadow",
                    title: "Box shadow",
                    subtitle: "A soft shadow behind and below the fixed box.",
                    isOn: Binding(get: { probe.flags.boxShadow }, set: { probe.flags.boxShadow = $0 })
                )
                PerfToggleRow(
                    icon: "sparkle",
                    title: "Box glow",
                    subtitle: "A halo around the fixed box in the title's colour.",
                    isOn: Binding(get: { probe.flags.boxGlow }, set: { probe.flags.boxGlow = $0 })
                )
                PerfToggleRow(
                    icon: "circle.dashed",
                    title: "Vignette",
                    subtitle: "The background's corners and edges a little darker.",
                    isOn: Binding(get: { probe.flags.vignette }, set: { probe.flags.vignette = $0 })
                )
                CueDropdown(
                    title: "Grain",
                    subtitle: "Fine static grain over the background (behind the posters).",
                    icon: "aqi.medium",
                    selection: String(probe.flags.grain),
                    options: [(0.0, "Off"), (0.05, "Light"), (0.1, "Medium"), (0.16, "Strong"), (0.25, "Very strong")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.grain = v }
                }
                PerfToggleRow(
                    icon: "circle.dashed.inset.filled",
                    title: "Billboard vignette",
                    subtitle: "The billboard's edges and corners darker (stronger than the rows' vignette), so the dots read on any picture.",
                    isOn: Binding(get: { probe.flags.billboardVignette }, set: { probe.flags.billboardVignette = $0 })
                )
                CueDropdown(
                    title: "Details: picture edge",
                    subtitle: "The picture's bottom edge as it scrolls away: melting into the colours, or a plain edge with a shadow.",
                    icon: "square.3.layers.3d.down.right",
                    selection: probe.flags.detailsPictureEdge,
                    options: [CueDropdownOption("melt", "Melts into the colours"),
                              CueDropdownOption("shadow", "Plain edge, shadow")]
                ) { raw in
                    probe.flags.detailsPictureEdge = raw
                }
                CueDropdown(
                    title: "Details: picture dim below",
                    subtitle: "How much the picture darkens on Episodes and More (the left fade stays).",
                    icon: "circle.lefthalf.filled",
                    selection: String(probe.flags.detailsPictureDim),
                    options: [0.0, 0.3, 0.45, 0.6, 0.75].map {
                        CueDropdownOption(String($0), $0 == 0 ? "Off" : "\(Int(($0 * 100).rounded())) %")
                    }
                ) { raw in
                    if let v = Double(raw) { probe.flags.detailsPictureDim = v }
                }
                PerfToggleRow(
                    icon: "captions.bubble",
                    title: "Button captions",
                    subtitle: "Details: the focused icon button's name, small, under it.",
                    isOn: Binding(get: { probe.flags.buttonCaptions }, set: { probe.flags.buttonCaptions = $0 })
                )
                PerfToggleRow(
                    icon: "network.slash",
                    title: "MDBList off",
                    subtitle: "No MDBList requests at all (its daily limit, while developing). Cached ratings still show; otherwise the catalog's IMDb score.",
                    isOn: Binding(get: { probe.flags.noMDBList }, set: { probe.flags.noMDBList = $0 })
                )
                CueDropdown(
                    title: "Card edge",
                    subtitle: "How the posters, cards and the box stand off the background.",
                    icon: "rectangle.on.rectangle",
                    selection: probe.flags.cardEdge,
                    options: FixedFocusCardEdge.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.cardEdge = raw
                }
                CueDropdown(
                    title: "Left fade: Episodes",
                    subtitle: "The left fade on the Detail page's Episodes and More, compared to the overview's.",
                    icon: "rectangle.lefthalf.inset.filled",
                    selection: String(probe.flags.episodesLeftFade),
                    options: [0.0, 0.4, 0.6, 0.8, 0.9, 1.0].map {
                        CueDropdownOption(String($0), $0 == 0 ? "Off" : "\(Int(($0 * 100).rounded())) %")
                    }
                ) { raw in
                    if let v = Double(raw) { probe.flags.episodesLeftFade = v }
                }
                CueDropdown(
                    title: "Left fade: Home rows",
                    subtitle: "The billboard's left fade behind Home's rows, compared to the billboard's.",
                    icon: "rectangle.lefthalf.inset.filled",
                    selection: String(probe.flags.homeLeftFade),
                    options: [0.0, 0.2, 0.3, 0.4, 0.6, 0.8, 0.9, 1.0].map {
                        CueDropdownOption(String($0), $0 == 0 ? "Off" : "\(Int(($0 * 100).rounded())) %")
                    }
                ) { raw in
                    if let v = Double(raw) { probe.flags.homeLeftFade = v }
                }
                CueDropdown(
                    title: "Details: buttons focus speed",
                    subtitle: "How fast Play and the round buttons light up and grow when focused (spring, no bounce).",
                    icon: "hand.tap",
                    selection: String(probe.flags.buttonFocusTime),
                    options: [(0.08, "0.08 s"), (0.1, "0.10 s"), (0.12, "0.12 s"), (0.15, "0.15 s"),
                              (0.2, "0.20 s"), (0.0, "As Motion: Focus")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.buttonFocusTime = v }
                }
                PerfToggleRow(
                    icon: "circle.dashed",
                    title: "Details: vignette below",
                    subtitle: "Below the billboard: the rows' vignette (corners and edges a little darker) over the blurred picture.",
                    isOn: Binding(get: { probe.flags.detailsVignetteBelow }, set: { probe.flags.detailsVignetteBelow = $0 })
                )
                CueDropdown(
                    title: "Details: picture blur below",
                    subtitle: "How much the picture blurs on Episodes and More — and Home's \"Artwork, blurred\" background (a still, made once).",
                    icon: "drop.halffull",
                    selection: String(probe.flags.detailsPictureBlur),
                    options: [(0.0, "Off"), (6.0, "Light"), (9.0, "Light–medium"), (12.0, "Medium"), (20.0, "Strong"), (32.0, "Very strong")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.detailsPictureBlur = v }
                }
                CueDropdown(
                    title: "Focus outline",
                    subtitle: "Every focused card's outline, fixed box and moving focus alike.",
                    icon: "square.dashed",
                    selection: probe.flags.focusOutline == "strong" ? "strong" : "soft",
                    options: [CueDropdownOption("strong", "4 pt, 85 %"), CueDropdownOption("soft", "3 pt, 75 %")]
                ) { raw in
                    probe.flags.focusOutline = raw
                }
                CueDropdown(
                    title: "Billboard ratings",
                    subtitle: "The ratings next to the badge: the sources' logos, or chips in the badge's shape with the source's name in its colour.",
                    icon: "star.leadinghalf.filled",
                    selection: probe.flags.billboardRatings,
                    options: MDBListRatingsRow.ChipStyle.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.billboardRatings = raw
                }
                CueDropdown(
                    title: "Badge",
                    subtitle: "The ENDED / ONGOING badge on the billboard and on Details.",
                    icon: "capsule",
                    selection: probe.flags.badgeStyle,
                    options: TitleBadge.Style.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.badgeStyle = raw
                }
                PerfToggleRow(
                    icon: "rectangle.grid.1x2",
                    title: "Details: rows",
                    subtitle: "Details built like Home: the billboard, then the seasons' episodes and More Like This as Home's rows, with Home's scroll. Off: the old pages.",
                    isOn: Binding(get: { probe.flags.detailsOnRows }, set: { probe.flags.detailsOnRows = $0 })
                )
                PerfToggleRow(
                    icon: "rectangle.stack",
                    title: "Home: billboard like Details",
                    subtitle: "Down from the billboard as on Details: one shorter move, the dots end beside the first row's name, the picture stays, blurs and gives way to the colours. Off: the picture scrolls away whole.",
                    isOn: Binding(get: { probe.flags.homeBillboardRigid }, set: { probe.flags.homeBillboardRigid = $0 })
                )
                PerfToggleRow(
                    icon: "text.justify",
                    title: "Summary: justified",
                    subtitle: "Billboard and Details: the summary's lines filled to the full width (word gaps stretched, long words hyphenated). Off: ragged right.",
                    isOn: Binding(get: { probe.flags.summaryJustified }, set: { probe.flags.summaryJustified = $0 })
                )
                CueDropdown(
                    title: "Billboard bottom fade",
                    subtitle: "How far up the billboard's picture fades into the colours at its bottom — where it melts away scrolling down.",
                    icon: "rectangle.bottomhalf.inset.filled",
                    selection: String(probe.flags.billboardBottomFade),
                    options: [(0.0, "Off (plain edge)"), (120.0, "120 pt"), (200.0, "200 pt"), (300.0, "300 pt"), (420.0, "420 pt")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.billboardBottomFade = v }
                }
                CueDropdown(
                    title: "Previous poster",
                    subtitle: "The poster left of the box in the focused row: how visible it stays.",
                    icon: "rectangle.portrait.lefthalf.inset.filled",
                    selection: String(probe.flags.previousPosterAlpha),
                    options: [(0.3, "30 %"), (0.45, "45 %"), (0.6, "60 %"), (0.75, "75 %"), (1.0, "Not dimmed")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.previousPosterAlpha = v }
                }
                PerfToggleRow(
                    icon: "sun.max",
                    title: "Background glow",
                    subtitle: "A soft glow in the background's colour. Off: an even gradient.",
                    isOn: Binding(get: { probe.flags.backgroundGlow }, set: { probe.flags.backgroundGlow = $0 })
                )
            }

            SettingsGroupCard(title: "Motion", subtitle: "Durations of the four motion curves (springs, no bounce). Applies on the next press.") {
                CueDropdown(
                    title: "Focus",
                    subtitle: "Focus outline, highlights, button focus.",
                    icon: "scope",
                    selection: String(probe.flags.motion.focus),
                    options: [0.12, 0.16, 0.2, 0.25, 0.3].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.motion.focus = v }
                }
                CueDropdown(
                    title: "Move",
                    subtitle: "Rows sliding, wrapping, changing row.",
                    icon: "arrow.left.and.right",
                    selection: String(probe.flags.motion.move),
                    options: [0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.6].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.motion.move = v }
                }
                CueDropdown(
                    title: "Fade",
                    subtitle: "Crossfades: box art, text, chrome.",
                    icon: "circle.lefthalf.filled",
                    selection: String(probe.flags.motion.fade),
                    options: [0.15, 0.2, 0.25, 0.3, 0.4].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.motion.fade = v }
                }
                CueDropdown(
                    title: "Up / Down",
                    subtitle: "Home: a row change (the row moves up, the box opens).",
                    icon: "arrow.up.arrow.down",
                    selection: String(probe.flags.motion.vertical),
                    options: [0.45, 0.5, 0.55, 0.6, 0.65, 0.75, 0.85].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.motion.vertical = v }
                }
                CueDropdown(
                    title: "Continue Watching step",
                    subtitle: "Home: one step in Continue Watching (a whole box-wide card).",
                    icon: "rectangle.on.rectangle",
                    selection: String(probe.flags.motion.continueMove),
                    options: [0.35, 0.45, 0.55, 0.65].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.motion.continueMove = v }
                }
                CueDropdown(
                    title: "Left / Right curve",
                    subtitle: "Home: the curve of a step (its duration is Move). Up/Down keeps its spring.",
                    icon: "point.topleft.down.curvedto.point.bottomright.up",
                    selection: probe.flags.horizontalCurve,
                    options: FixedFocusMotion.Curve.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.horizontalCurve = raw
                }
                PerfToggleRow(
                    icon: "arrow.left.and.right.square",
                    title: "Box change: drift",
                    subtitle: "Home: the box's new title fades in while shifting a little in the direction you move. Off: plain crossfade.",
                    isOn: Binding(get: { probe.flags.boxDrift }, set: { probe.flags.boxDrift = $0 })
                )
                CueDropdown(
                    title: "Billboard scroll",
                    subtitle: "Home: the scroll between the billboard and the rows (both ways). Auto: from Up / Down, a little longer for the longer distance.",
                    icon: "rectangle.portrait.and.arrow.forward",
                    selection: String(probe.flags.billboardScrollDuration),
                    options: [(0.0, "Auto (≈ 0.7 s at 0.5 s Up / Down)"), (0.4, "0.4 s"), (0.45, "0.45 s"), (0.5, "0.5 s"),
                              (0.55, "0.55 s"), (0.6, "0.6 s"), (0.65, "0.65 s"), (0.7, "0.7 s"), (0.8, "0.8 s")]
                        .map { CueDropdownOption(String($0.0), $0.1) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.billboardScrollDuration = v }
                }
                PerfToggleRow(
                    icon: "text.line.first.and.arrowtriangle.forward",
                    title: "Next row's name: same pace",
                    subtitle: "Home, between the billboard and the rows: the name moves the whole way, slower than the cards, and they meet at the row's place. Off: it holds on the billboard until the cards reach it, then moves with them.",
                    isOn: Binding(get: { probe.flags.nextNameSamePace }, set: { probe.flags.nextNameSamePace = $0 })
                )
                PerfToggleRow(
                    icon: "rectangle.portrait.and.arrow.forward",
                    title: "Continue Watching, Saved for Later: moving focus",
                    subtitle: "Home: the rows stay and focus moves across their cards, a caption under each (as collections). Off: the fixed box, at the cards' own size.",
                    isOn: Binding(get: { probe.flags.rowsMovingFocus }, set: { probe.flags.rowsMovingFocus = $0 })
                )
                CueDropdown(
                    title: "Moving focus: lift",
                    subtitle: "Home, rows with moving focus (collections; Continue Watching and Saved for Later when switched): how much the focused card grows, with a shadow under it. Off: it keeps its size, only outlined — as the fixed box.",
                    icon: "arrow.up.left.and.arrow.down.right",
                    selection: String(probe.flags.movingFocusLift),
                    options: (0...8).map { CueDropdownOption(String($0), $0 == 0 ? "Off (outline only)" : "\($0) %") }
                ) { raw in
                    if let v = Int(raw) { probe.flags.movingFocusLift = v }
                }
                PerfToggleRow(
                    icon: "shadow",
                    title: "Moving focus: shadow",
                    subtitle: "Home, rows with moving focus: a soft shadow under the lifted card.",
                    isOn: Binding(get: { probe.flags.movingFocusShadow }, set: { probe.flags.movingFocusShadow = $0 })
                )
                CueDropdown(
                    title: "Up / Down curve",
                    subtitle: "Home: the curve of a row change (its duration is Up / Down; damping only applies to Spring).",
                    icon: "point.bottomleft.forward.to.point.topright.scurvepath",
                    selection: probe.flags.verticalCurve,
                    options: FixedFocusMotion.Curve.allCases.map { CueDropdownOption($0.rawValue, $0.displayName) }
                ) { raw in
                    probe.flags.verticalCurve = raw
                }
                CueDropdown(
                    title: "Up / Down damping",
                    subtitle: "1.0: no give at all. Lower: a slight settle at the end (no visible bounce down to about 0.85).",
                    icon: "waveform.path.ecg",
                    selection: String(probe.flags.motion.verticalDamping),
                    options: [1.0, 0.95, 0.9, 0.85].map { CueDropdownOption(String($0), String(format: "%.2f", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.motion.verticalDamping = v }
                }
                CueDropdown(
                    title: "Present",
                    subtitle: "Screen changes: billboard ⇄ Details, box → Details.",
                    icon: "rectangle.expand.vertical",
                    selection: String(probe.flags.motion.present),
                    options: [0.35, 0.4, 0.45, 0.5, 0.6].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.motion.present = v }
                }
            }

            SettingsGroupCard(title: "Measure", subtitle: "Live frame rate over the whole app") {
                PerfToggleRow(
                    icon: "speedometer",
                    title: "Show FPS overlay",
                    subtitle: "Overlay a live frames-per-second read-out on the whole app (green = smooth, amber = some drops, red = janky), so you can see the effect of these switches while you browse. Off by default.",
                    isOn: s.showFPSOverlay
                )
            }

            SettingsGroupCard(
                title: "Render bisect",
                subtitle: "Temporary: remove one render cost at a time on Home and watch the FPS overlay"
            ) {
                PerfToggleRow(
                    icon: "drop.fill",
                    title: "No live glass",
                    subtitle: "Glass surfaces (end cards, chevrons, dots, top bar) become a flat fill.",
                    isOn: Binding(get: { probe.flags.noGlass }, set: { probe.flags.noGlass = $0 })
                )
                PerfToggleRow(
                    icon: "square.3.layers.3d.down.backward",
                    title: "No stage scrim",
                    subtitle: "Removes the three full-screen darkening gradients.",
                    isOn: Binding(get: { probe.flags.noScrim }, set: { probe.flags.noScrim = $0 })
                )
                PerfToggleRow(
                    icon: "shadow",
                    title: "No shadows",
                    subtitle: "Every shadow on Home: cards, box, logos, focus glow.",
                    isOn: Binding(get: { probe.flags.noShadows }, set: { probe.flags.noShadows = $0 })
                )
                PerfToggleRow(
                    icon: "square.dashed",
                    title: "No card rims",
                    subtitle: "The thin gradient edge on every card.",
                    isOn: Binding(get: { probe.flags.noRims }, set: { probe.flags.noRims = $0 })
                )
                PerfToggleRow(
                    icon: "circle.lefthalf.filled",
                    title: "No ambient backdrop",
                    subtitle: "The blurred artwork behind the rows.",
                    isOn: Binding(get: { probe.flags.noAmbient }, set: { probe.flags.noAmbient = $0 })
                )
                PerfToggleRow(
                    icon: "paintbrush",
                    title: "No title tint",
                    subtitle: "Fixed dark background instead of the colour taken from the focused title.",
                    isOn: Binding(get: { probe.flags.noTint }, set: { probe.flags.noTint = $0 })
                )
                PerfToggleRow(
                    icon: "photo",
                    title: "No billboard artwork",
                    subtitle: "The billboard's full-screen image.",
                    isOn: Binding(get: { probe.flags.noBackdrop }, set: { probe.flags.noBackdrop = $0 })
                )
                PerfToggleRow(
                    icon: "arrow.down.right.and.arrow.up.left",
                    title: "Cap backdrops at 2560 px",
                    subtitle: "Decode full-screen art smaller (relaunch or browse to reload images).",
                    isOn: Binding(get: { probe.flags.capBackdrop }, set: { probe.flags.capBackdrop = $0 })
                )
                PerfToggleRow(
                    icon: "pause.circle",
                    title: "No Home animations",
                    subtitle: "Every step snaps. Separates animation cost from drawing cost.",
                    isOn: Binding(get: { probe.flags.noAnimations }, set: { probe.flags.noAnimations = $0 })
                )
                PerfActionRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset bisect switches",
                    subtitle: "Everything back on.",
                    action: { probe.flags = .init() }
                )
            }

        }
    }
}
