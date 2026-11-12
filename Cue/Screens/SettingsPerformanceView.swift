import SwiftUI

/// Settings → Developer, second half: the diagnostics (player HUD, the LAN
/// log).
struct PerformanceSettings: View {
    @ObservedObject private var store = PerformanceSettingsStore.shared
    @State private var showWhy = false

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
                    icon: "sparkles.rectangle.stack",
                    title: "Cue's own rows",
                    subtitle: "Home, Movies and Series rows made by Cue from TMDB and what you watch, instead of the add-ons' catalogs. Pictures and logos from TMDB.",
                    isOn: s.cueRows
                )

                Button { showWhy = true } label: {
                    PerfRowLabel(icon: "questionmark.text.page", title: "Why These Rows",
                                 subtitle: "What Cue read from your watching, and why each row is on Home, Movies and Series today.") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(CuePalette.textTertiary)
                    }
                }
                .buttonStyle(PlainCardButtonStyle())
                .sheet(isPresented: $showWhy) { CueRowsWhyView() }

                PerfToggleRow(
                    icon: "waveform.path.ecg",
                    title: "Playback diagnostics HUD",
                    subtitle: "Live engine, fps, dropped frames, A/V drift, bitrate and buffer depth over the video. For chasing stutter on this box.",
                    isOn: s.showPlayerDiagnostics
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
                .foregroundStyle(CuePalette.textTertiary)
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
                    .foregroundStyle(CuePalette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(CuePalette.textSecondary)
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

/// Settings → Developer, first half: the FPS overlay.
struct MeasureSettings: View {
    @ObservedObject private var store = PerformanceSettingsStore.shared

    private var s: Binding<PerformanceSettingsStore.Settings> {
        Binding(get: { store.settings }, set: { store.settings = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.xl) {
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

/// Developer → Why These Rows: the taste Cue read and each row's reason,
/// from the last saved build of this profile's rows.
private struct CueRowsWhyView: View {
    @State private var saved: CueRows.Saved?
    @State private var loaded = false

    private var lines: [(String, String)] {
        guard let saved else { return [] }
        var out: [(String, String)] = []
        let built = saved.builtAt.formatted(date: .abbreviated, time: .shortened)
        out.append(("Built \(built)", "Taste from \(saved.titles) titles you watched or saved; rows rotate daily (\(saved.day))."))
        if !saved.taste.isEmpty {
            out.append(("Your taste", saved.taste.map { "\($0.label) \(Int(($0.share * 100).rounded())) %" }
                .joined(separator: " · ")))
        }
        if !saved.passedOver.isEmpty {
            out.append(("Passed over", "Left out for 30 days after you looked and moved on three times: "
                        + saved.passedOver.joined(separator: ", ")))
        }
        for tab in ["home", "movie", "series"] {
            let name = tab == "home" ? "Home" : tab == "movie" ? "Movies" : "Series"
            for why in saved.why where why.tab == tab { out.append(("\(name) · \(why.title)", why.reason)) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loaded && saved == nil {
                    Text("No rows built yet. Turn on Cue's own rows and open Home.")
                        .font(.system(size: 24))
                        .foregroundStyle(CuePalette.textSecondary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Button {} label: { WhyLine(title: line.0, text: line.1) }
                        .buttonStyle(PlainCardButtonStyle())
                }
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 60)
        }
        .task { saved = await CueRows.saved(); loaded = true }
    }
}

private struct WhyLine: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(CuePalette.textPrimary)
            Text(text)
                .font(.system(size: 24))
                .foregroundStyle(CuePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsRowBackground(isFocused: isFocused))
    }
}
