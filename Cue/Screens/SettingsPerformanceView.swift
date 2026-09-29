import SwiftUI

/// Settings → Performance: per-effect switches so slower Apple TVs (HD,
/// 4K 1st gen) can turn off exactly the things causing lag — each row says
/// what the effect costs and what OFF looks like. All ON = the full look.
struct PerformanceSettingsDetail: View {
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
        DetailScaffold(title: SettingsCategory.performance.title,
                       subtitle: SettingsCategory.performance.subtitle) {

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


/// Settings → Render Lab (top of Settings): the FPS overlay and the render
/// bisect switches in one place, for quick A/B runs while tuning Home.
struct RenderLabDetail: View {
    @ObservedObject private var store = PerformanceSettingsStore.shared
    @ObservedObject private var probe = RenderProbe.shared

    private var s: Binding<PerformanceSettingsStore.Settings> {
        Binding(get: { store.settings }, set: { store.settings = $0 })
    }

    var body: some View {
        DetailScaffold(title: SettingsCategory.renderLab.title,
                       subtitle: SettingsCategory.renderLab.subtitle) {
            SettingsGroupCard(title: "Home layout", subtitle: "Switch tabs to refresh Home.") {
                PerfToggleRow(
                    icon: "square.stack.3d.up",
                    title: "New Home",
                    subtitle: "Rows in UIKit: native focus, our own movement to the fixed box. Off: the previous Home, kept for reference.",
                    isOn: Binding(get: { probe.flags.uikitHome }, set: { probe.flags.uikitHome = $0 })
                )
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
                    options: [0.08, 0.12, 0.18, 0.25].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintDelay = v }
                }
                CueDropdown(
                    title: "Tint fade",
                    subtitle: "Title colour: how long the change of colour takes.",
                    icon: "circle.lefthalf.filled",
                    selection: String(probe.flags.tintFade),
                    options: [0.2, 0.25, 0.3, 0.4, 0.6].map { CueDropdownOption(String($0), String(format: "%.2f s", $0)) }
                ) { raw in
                    if let v = Double(raw) { probe.flags.tintFade = v }
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
