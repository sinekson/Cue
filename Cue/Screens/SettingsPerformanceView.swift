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

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.xl) {

            if store.reduceMotion { reduceMotionBanner }

            SettingsGroupCard(
                title: "Cards & rows",
                subtitle: "Posters and the rows they live in"
            ) {
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
                Text("Your system Accessibility setting is disabling the motion effects (card wiggle & lift, focus zoom, sidebar and button animations, artwork fade-in) regardless of the switches below.")
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


/// Settings → Developer, first half (Render Lab): the launch numbers and the
/// FPS overlay.
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
            }

            SettingsGroupCard(title: "Measure", subtitle: "Live frame rate over the whole app") {
                PerfToggleRow(
                    icon: "speedometer",
                    title: "Show FPS overlay",
                    subtitle: "Overlay a live frames-per-second read-out on the whole app (green = smooth, amber = some drops, red = janky), while you browse. Off by default.",
                    isOn: s.showFPSOverlay
                )
            }
        }
    }
}
