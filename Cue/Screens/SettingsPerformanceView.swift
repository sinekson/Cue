import SwiftUI

/// Settings → Developer, second half: the diagnostics (player HUD, scrub
/// previews, input debug, the LAN log).
struct PerformanceSettings: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var playerStore: PlayerSettingsStore
    @ObservedObject private var store = PerformanceSettingsStore.shared

    private var s: Binding<PerformanceSettingsStore.Settings> {
        Binding(get: { store.settings }, set: { store.settings = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.xl) {
            SettingsGroupCard(
                title: "Developer",
                subtitle: "Diagnostics — safe to leave off"
            ) {
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

            Text("These switches are per-device and don't sync to your account.")
                .font(.system(size: 18))
                .foregroundStyle(theme.palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

            SettingsGroupCard(title: "Search", subtitle: "Which order Search's results come in.") {
                PerfToggleRow(
                    icon: "arrow.up.arrow.down",
                    title: "Search: Cue's order",
                    subtitle: "On: titles and people whose name (or a word of it) starts with what's typed, the best known first, an exact name lifted. Off: TMDB's own order, as it comes.",
                    isOn: Binding(get: { probe.flags.searchOwnOrder }, set: { probe.flags.searchOwnOrder = $0 })
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
