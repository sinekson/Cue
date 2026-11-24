import SwiftUI

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
