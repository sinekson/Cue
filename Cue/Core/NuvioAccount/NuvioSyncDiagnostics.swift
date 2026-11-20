import Foundation

enum NuvioSyncLogEntry {
    enum Level { case info, success, warning, failure }
}

/// Sync milestones, into the log (Settings → Developer → Log).
enum NuvioSyncDiagnostics {
    static func record(_ level: NuvioSyncLogEntry.Level, area: String, _ message: String) {
        AppProbe.sync("\(area): \(message)")
        if level == .failure { AppProbe.warn("sync", "\(area): \(message)") }
    }
}
