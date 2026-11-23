import SwiftUI

/// Settings → Developer: three tools — the Frame Rate overlay, the Playback
/// HUD and the Log (its sessions on a page of their own). Per device,
/// never synced.
struct DeveloperSettingsDetail: View {
    @ObservedObject private var store = PerformanceSettingsStore.shared
    @State private var logOn = ProbeGate.isEnabled
    @State private var sessions: [CueLog.Session]?

    var body: some View {
        SettingsPage(title: SettingsCategory.developer.title,
                     subtitle: "Tools for finding what's slow or broken. They stay on this Apple TV.") {
            SettingsSection {
                SettingsOptionsRow(
                    title: "Frame Rate",
                    description: "Frames per second over everything, top right. Full adds the last seconds' "
                        + "frame times, dropped frames, CPU and memory. It sees the main thread's frames; "
                        + "frames the GPU drops need Instruments.",
                    options: PerformanceSettingsStore.FrameRate.allCases.map {
                        SettingsOption(id: $0.rawValue, label: $0.rawValue.capitalized)
                    },
                    selection: store.settings.frameRate.rawValue
                ) { id in
                    store.settings.frameRate = PerformanceSettingsStore.FrameRate(rawValue: id) ?? .off
                }
                SettingsToggleRow(
                    title: "Playback HUD",
                    description: "Live numbers over the video: the decoding path, dropped frames, bitrate, "
                        + "what's buffered, the audio sent and what happened to the session.",
                    isOn: $store.settings.showPlaybackHUD
                )
            }
            SettingsSection(title: "Log") {
                SettingsToggleRow(
                    title: "Log",
                    description: "Writes what the app does to a file on this Apple TV, a week at most: "
                        + "pages, loads, playback, stalls, hangs and crashes. To mark a moment, press "
                        + "Play/Pause three times (in the player, the flag on the shelf).",
                    isOn: Binding(get: { logOn }, set: { on in
                        logOn = on
                        ProbeGate.store(on)
                    })
                )
                SettingsLinkRow(title: "Sessions", value: sessions.map(Self.summary)) {
                    LogSessionsPage(sessions: $sessions)
                }
            }
            if logOn, let address = LogServer.address {
                SettingsSection {
                    SettingsInfoRows {
                        SettingsInfoRow(title: "Address", value: address)
                    }
                }
            }
        }
        .task { sessions = await CueLog.sessions() }
    }

    private static func summary(_ sessions: [CueLog.Session]) -> String {
        let marks = sessions.reduce(0) { $0 + $1.marks }
        let crashes = sessions.filter(\.crashed).count
        var parts = ["\(sessions.count)"]
        if marks > 0 { parts.append(marks == 1 ? "1 mark" : "\(marks) marks") }
        if crashes > 0 { parts.append(crashes == 1 ? "1 crash" : "\(crashes) crashes") }
        return parts.joined(separator: " · ")
    }
}

/// The log's sessions, newest first, each with its marks and problems.
struct LogSessionsPage: View {
    @Binding var sessions: [CueLog.Session]?

    var body: some View {
        SettingsPage(title: "Sessions",
                     subtitle: "One per launch, kept a week (50 MB at most). Marks, warnings, hangs and "
                        + "crashes are listed in each.") {
            SettingsSection {
                SettingsButtonRow(title: "Clear Log", description: "Removes every session but this one.") {
                    CueLog.clear()
                    Task { sessions = await CueLog.sessions() }
                }
            }
            if let sessions, !sessions.isEmpty {
                SettingsSection {
                    ForEach(sessions) { session in
                        SettingsLinkRow(title: Self.title(session), value: Self.value(session)) {
                            LogSessionPage(session: session)
                        }
                    }
                }
            }
        }
    }

    static func title(_ session: CueLog.Session) -> String {
        DateFormatter.settingsWhen.string(from: session.started) + (session.isCurrent ? " (now)" : "")
    }

    static func value(_ session: CueLog.Session) -> String {
        var parts: [String] = []
        if session.crashed { parts.append("Crashed") }
        if session.marks > 0 { parts.append(session.marks == 1 ? "1 mark" : "\(session.marks) marks") }
        if session.hangs > 0 { parts.append(session.hangs == 1 ? "1 hang" : "\(session.hangs) hangs") }
        parts.append(ByteCountFormatter.string(fromByteCount: session.bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

/// One session: what stood out in it, in order, its time on the right.
struct LogSessionPage: View {
    let session: CueLog.Session

    var body: some View {
        SettingsPage(title: LogSessionsPage.title(session),
                     subtitle: "Until \(session.ended.prefix(8)). The whole session: "
                        + "/log?session=\(session.url.deletingPathExtension().lastPathComponent)") {
            SettingsFocusHolder()
            SettingsSection {
                SettingsInfoRows {
                    if session.notable.isEmpty {
                        SettingsInfoRow(title: "Nothing stood out", value: "")
                    }
                    ForEach(session.notable) { line in
                        SettingsInfoRow(title: Self.label(line), value: String(line.time.prefix(8)))
                    }
                }
            }
        }
    }

    static func label(_ line: CueLog.Line) -> String {
        let name = switch line.tag {
        case "MARK": "Mark"
        case "WARN": "Warning"
        case "HANG": "Hang"
        case "EXIT": "Ended"
        default: "Crash"
        }
        return name + ": " + line.text
    }
}
