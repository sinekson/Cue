import AVFoundation
import Foundation
import Network
import SwiftUI
import UIKit

/// Reclaims the player's scratch space in `tmp/` at launch.
///
/// The engine's disk window (`tmp/aether-*`, up to 6 GB a session) is deleted
/// when the player closes, but a jetsam kill or a force-quit mid-film leaves
/// it behind with no owner. tvOS only purges `tmp/` once the box is nearly
/// full, so the sweep is ours, at launch: the one moment no session can own
/// any of it. CFNetwork's response spools (`tmp/CFNetworkDownload_*.tmp`)
/// leak the same way and go on the same pass.
enum PlayerTempSweep {
    /// The engine's disk window (its own sweeps wait hours, to be sure a
    /// directory isn't another session's), and the subtitle fonts libass
    /// was given (`cue-ass-fonts`, removed with the track — a kill left
    /// them: 192 MB seen).
    static let scratchPrefixes = ["aether-", "cue-ass-fonts"]
    static let spoolPrefix = "CFNetworkDownload_"

    /// Delete every orphaned player scratch directory and network spool file.
    ///
    /// Call once, at launch, BEFORE any playback can start. Runs off the main
    /// thread: this is thousands of unlinks and real filesystem work, and it
    /// must never sit in front of the first frame of UI.
    static func sweepAtLaunch() {
        Task.detached(priority: .utility) { sweep() }
    }

    /// The sweep itself. Synchronous — call it directly only from a background
    /// context (or a test).
    static func sweep() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey]
        ) else { return }

        var reclaimed: Int64 = 0
        var directories = 0
        var spools = 0

        for entry in entries {
            let name = entry.lastPathComponent
            if scratchPrefixes.contains(where: name.hasPrefix) {
                reclaimed += directorySize(of: entry, fm: fm)
                try? fm.removeItem(at: entry)
                directories += 1
            } else if name.hasPrefix(spoolPrefix) {
                reclaimed += Int64(
                    (try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                        .totalFileAllocatedSize ?? 0
                )
                try? fm.removeItem(at: entry)
                spools += 1
            }
        }

        guard directories > 0 || spools > 0 else { return }
        NSLog("[CueSweep] reclaimed %.1f MB — %d orphaned scratch dirs, %d network spool files",
              Double(reclaimed) / (1024 * 1024), directories, spools)
    }

    private static func directorySize(of url: URL, fm: FileManager) -> Int64 {
        guard let walker = fm.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64(
                (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
            )
        }
        return total
    }
}

/// The Log's switch (Settings → Developer → Log): the file log, the LAN
/// server and the watchdog together. On unless switched off, in every build:
/// the beta is daily driven with it, and a problem is only worth anything if
/// the log was running when it happened.
enum ProbeGate {
    /// Persisted choice; absent means on.
    static let defaultsKey = "cue.log.on.v1"

    private static let lock = NSLock()
    private static var enabled = false

    /// Read on every `PlayerProbe` call (including the scrub path), so it is a
    /// cheap lock, not a `UserDefaults` hit.
    static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    /// Once, from the app's `init`, before anything logs.
    static func configureFromDefaults() {
        // The old capture switch and the UserDefaults trails it fed.
        for key in ["cue.diag.capture.v1", "cue.sync.log.v1", "dev.flight", "dev.colorTrail", "dev.dvTrail"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        set(UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true)
    }

    private static func set(_ on: Bool) {
        lock.lock(); enabled = on; lock.unlock()
    }

    /// Settings' switch: everything it runs starts or stops with it.
    @MainActor static func store(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: defaultsKey)
        if on {
            set(true)
            CueLog.start()
            LogServer.shared.start()
            Watchdog.start()
        } else {
            CueLog.write("life", "log switched off")
            set(false)
            LogServer.shared.stop()
            CueLog.stop()
        }
    }
}

/// Live probe bus: timestamped EVENTS from anywhere, plus LEVELS pulled on
/// demand from whoever holds them. Every event also goes to the file log
/// (`CueLog`); the ring is what the live tail reads.
///
/// Gated by `ProbeGate`. When off, the `@autoclosure` message is never built,
/// so the call sites (including the scrub path) stay cheap.
enum PlayerProbe {
    /// Ring capacity: a whole scrub at full rate, so the live tail (drained
    /// twice a second) never loses an event.
    private static let capacity = 2000

    private static let lock = NSLock()
    private static var ring: [(seq: UInt64, at: Date, tag: String, line: String)] = []
    private static var nextSeq: UInt64 = 1
    static let startedAt = Date()

    /// Record one event. Safe from any thread or queue.
    nonisolated static func event(_ tag: String, _ line: @autoclosure () -> String) {
        guard ProbeGate.isEnabled else { return }
        let text = line()
        let at = Date()
        lock.lock()
        ring.append((nextSeq, at, tag, text))
        nextSeq &+= 1
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        lock.unlock()
        CueLog.write(tag, text, at: at)
    }

    /// Events newer than `seq`, formatted, with the sequence to ask from next.
    static func events(since seq: UInt64, limit: Int = capacity) -> (lines: [String], next: UInt64) {
        guard ProbeGate.isEnabled else { return ([], seq) }
        lock.lock()
        let fresh = ring.filter { $0.seq > seq }.suffix(limit)
        let next = ring.last?.seq ?? seq
        lock.unlock()
        return (fresh.map { entry in
            String(format: "%8.3f  %-9@ %@",
                   entry.at.timeIntervalSince(startedAt), entry.tag, entry.line)
        }, next)
    }

    // MARK: Counters and sticky notes

    /// Monotonic counters and last-value notes, the `[health]` block: every
    /// number here should be zero (or one) in a healthy session.
    private static var counters: [String: Int] = [:]
    private static var notes: [(key: String, value: String, at: Date)] = []
    private static var counterOrder: [String] = []

    nonisolated static func count(_ name: String, by amount: Int = 1) {
        guard ProbeGate.isEnabled else { return }
        lock.lock()
        if counters[name] == nil { counterOrder.append(name) }
        counters[name, default: 0] += amount
        lock.unlock()
    }

    nonisolated static func note(_ key: String, _ value: @autoclosure () -> String) {
        guard ProbeGate.isEnabled else { return }
        let v = value()
        lock.lock()
        notes.removeAll { $0.key == key }
        notes.append((key, v, Date()))
        lock.unlock()
    }

    nonisolated static func healthLines() -> [String] {
        guard ProbeGate.isEnabled else { return [] }
        lock.lock()
        let c = counterOrder.compactMap { name -> String? in
            guard let value = counters[name] else { return nil }
            return "\(name)=\(value)"
        }
        let n = notes.map { note -> String in
            String(format: "%@ = %@  (%.1fs ago)", note.key, note.value,
                   Date().timeIntervalSince(note.at))
        }
        lock.unlock()
        var out: [String] = []
        var row = ""
        for item in c {
            if row.count + item.count + 2 > 96 { out.append(row); row = "" }
            row += (row.isEmpty ? "" : "  ") + item
        }
        if !row.isEmpty { out.append(row) }
        out.append(contentsOf: n)
        return out
    }

    // MARK: Levels

    /// Named sampler closures, called on the main actor when a reader asks.
    @MainActor private static var samplers: [(name: String, sample: () -> [String])] = []

    @MainActor static func register(_ name: String, _ sample: @escaping () -> [String]) {
        samplers.removeAll { $0.name == name }
        samplers.append((name, sample))
    }

    @MainActor static func unregister(_ name: String) {
        samplers.removeAll { $0.name == name }
    }

    /// When the running executable was built: which build is answering.
    static let buildStamp: String = {
        guard let exe = Bundle.main.executableURL,
              let date = try? exe.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }()

    /// Resident footprint in MB, or 0 if the kernel won't say.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    /// The process's CPU use, all threads, in percent of one core.
    nonisolated static func cpuPercent() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }

    @MainActor static func levels() -> [String] {
        var out: [String] = [
            String(format: "[build] %@   up=%.0fs   mem=%.0fMB",
                   buildStamp, Date().timeIntervalSince(startedAt), footprintMB()),
        ]
        for sampler in samplers {
            let lines = sampler.sample()
            guard !lines.isEmpty else { continue }
            out.append("[\(sampler.name)]")
            out.append(contentsOf: lines.map { "  " + $0 })
        }
        let health = healthLines()
        if !health.isEmpty {
            out.append("[health]")
            out.append(contentsOf: health.map { "  " + $0 })
        }
        return out
    }
}

extension Bool {
    /// Compact yes/no for probe lines.
    var probe: String { self ? "Y" : "n" }
}

/// The log on disk: one file per launch in Application Support/Logs, every
/// probe event as a line ("14:03:22.123  tag    text"), kept 7 days and
/// 50 MB at most. Lines are written as they come (one `write` each, no
/// buffer), so a crash loses nothing that was already logged.
///
/// tvOS has no MetricKit, so crashes are caught here: an uncaught exception
/// and the fatal signals (Swift's traps are SIGTRAP) write a CRASH line and
/// the stack before the app goes. A session that ended in the foreground
/// with neither (killed for memory, a watchdog, a force stop) gets an EXIT
/// line at the next launch.
enum CueLog {
    /// In Caches: tvOS lets an app write nowhere else (Application Support,
    /// the simulator's place for it, can't be made on the box: nothing was
    /// ever kept there). Clear Cache leaves it; tvOS may empty it when short
    /// of space.
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
    private static let keepDays: TimeInterval = 7
    private static let keepBytes: Int64 = 50 * 1_048_576
    private static let queue = DispatchQueue(label: "cue.log", qos: .utility)

    /// The open session file. Read by the crash handlers, so a plain global.
    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private(set) static var current: URL?

    /// Tags the Log's pages pick out of a session.
    static let markTag = "MARK"
    static let notable: Set<String> = ["MARK", "WARN", "CRASH", "EXIT", "HANG"]

    /// Only on `queue`.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static let fileName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    static func start() {
        guard ProbeGate.isEnabled else { return }
        queue.sync {
            guard fd < 0 else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let previous = files().first { closeOut(previous) }
            prune()
            let url = folder.appendingPathComponent(fileName.string(from: Date()) + ".log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fd = open(url.path, O_WRONLY | O_APPEND)
            current = url
        }
        installCrashHandlers()
        write("life", header)
    }

    static func stop() {
        queue.sync {
            if fd >= 0 { close(fd) }
            fd = -1
            current = nil
        }
    }

    /// One line, from anywhere.
    nonisolated static func write(_ tag: String, _ text: String, at: Date = Date()) {
        queue.async {
            guard fd >= 0 else { return }
            let pad = tag.count < 6 ? String(repeating: " ", count: 6 - tag.count) : ""
            put(stamp.string(from: at) + "  " + tag + pad + " " + text + "\n")
        }
    }

    private static func put(_ line: String) {
        line.utf8CString.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }

    /// A moment marked from the remote: the line to look for later.
    @MainActor static func mark(from place: String) {
        PlayerProbe.event(markTag, "marked \(place) · \(AppProbe.place)")
    }

    private static var header: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #if DEBUG
        let kind = "Debug"
        #else
        let kind = "Release"
        #endif
        return "Cue \(version) (\(build)) \(kind), built \(PlayerProbe.buildStamp) · \(model) · tvOS "
            + ProcessInfo.processInfo.operatingSystemVersionString
            + String(format: " · %.0f MB", PlayerProbe.footprintMB())
    }

    // MARK: Files

    /// Session files, newest first.
    static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func started(_ url: URL) -> Date? {
        fileName.date(from: url.deletingPathExtension().lastPathComponent)
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Older than a week, then the oldest past 50 MB.
    private static func prune() {
        var total: Int64 = 0
        for url in files() {
            let old = started(url).map { Date().timeIntervalSince($0) > keepDays * 86_400 } ?? true
            total += size(url)
            if old || total > keepBytes { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Everything but the session being written.
    /// How many sessions there are (Settings' Sessions row), without reading them.
    static func sessionCount() -> Int { queue.sync { files().count } }

    static func clear() {
        queue.sync {
            for url in files() where url != current { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The last session ended in the foreground with no crash line: an EXIT.
    /// In the background is a normal end (tvOS reclaims suspended apps).
    private static func closeOut(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        let length = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: length > 65_536 ? length - 65_536 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        try? handle.close()
        let lines = tail.split(separator: "\n")
        if lines.contains(where: { $0.contains("  CRASH ") || $0.contains("  EXIT ") }) { return }
        let lastLife = lines.last { $0.contains("  life   lifecycle ") }
        if lastLife?.hasSuffix("background") == true || lines.last?.contains("log switched off") == true { return }
        let last = lines.last.map { String($0.prefix(12)) } ?? "?"
        let line = "\(last)  EXIT   ended unexpectedly in the foreground after \(last): "
            + "killed (memory, a watchdog) or stopped from Xcode; no crash was caught\n"
        if let out = try? FileHandle(forWritingTo: url) {
            _ = try? out.seekToEnd()
            try? out.write(contentsOf: Data(line.utf8))
            try? out.close()
        }
    }

    // MARK: Crashes

    private static let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]
    /// Prepared at install, so the handler only writes what's ready.
    nonisolated(unsafe) private static var signalLines = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 32)
    nonisolated(unsafe) private static var frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
    nonisolated(unsafe) private static var exceptionWritten = false
    nonisolated(unsafe) private static var installed = false

    private static func installCrashHandlers() {
        guard !installed else { return }
        installed = true
        let names: [Int32: String] = [
            SIGABRT: "SIGABRT (abort)", SIGSEGV: "SIGSEGV (bad memory access)",
            SIGBUS: "SIGBUS (bad memory access)", SIGILL: "SIGILL (illegal instruction)",
            SIGTRAP: "SIGTRAP (a Swift trap: force unwrap, fatalError, out of range)",
            SIGFPE: "SIGFPE (arithmetic)",
        ]
        for index in 0..<32 { signalLines[index] = nil }
        for (signal, name) in names {
            signalLines[Int(signal)] = strdup("--:--:--.---  CRASH  \(name)\n")
        }
        NSSetUncaughtExceptionHandler { exception in
            CueLog.exceptionWritten = true
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let text = "--:--:--.---  CRASH  \(exception.name.rawValue): \(exception.reason ?? "")\n\(stack)\n"
            if CueLog.fd >= 0 { CueLog.put(text) }
        }
        for signal in fatalSignals {
            Darwin.signal(signal) { number in
                if CueLog.fd >= 0 {
                    if !CueLog.exceptionWritten, number >= 0, number < 32, let line = CueLog.signalLines[Int(number)] {
                        _ = Darwin.write(CueLog.fd, line, strlen(line))
                    }
                    let count = backtrace(CueLog.frames, 128)
                    backtrace_symbols_fd(CueLog.frames, count, CueLog.fd)
                }
                Darwin.signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    // MARK: Reading back

    struct Line: Identifiable, Hashable {
        let id: Int
        let time: String
        let tag: String
        let text: String
    }

    struct Session: Identifiable {
        let url: URL
        var id: String { url.lastPathComponent }
        let started: Date
        let bytes: Int64
        /// The last line's time.
        let ended: String
        let notable: [Line]
        let isCurrent: Bool
        var marks: Int { notable.filter { $0.tag == CueLog.markTag }.count }
        var crashed: Bool { notable.contains { $0.tag == "CRASH" || $0.tag == "EXIT" } }
        var hangs: Int { notable.filter { $0.tag == "HANG" }.count }
        var warnings: Int { notable.filter { $0.tag == "WARN" }.count }
    }

    /// Every session with its marks and problems. Reads the files: off main.
    static func sessions() async -> [Session] {
        let current = queue.sync { CueLog.current }
        return await Task.detached(priority: .userInitiated) {
            files().compactMap { url -> Session? in
                guard let started = started(url), let data = try? Data(contentsOf: url) else { return nil }
                var notable: [Line] = []
                var ended = ""
                var index = 0
                String(decoding: data, as: UTF8.self).enumerateLines { raw, _ in
                    index += 1
                    guard raw.count > 21 else { return }
                    let time = String(raw.prefix(12))
                    if time.first?.isNumber == true { ended = time }
                    let rest = raw.dropFirst(14)
                    let tag = String(rest.prefix { $0 != " " })
                    guard notable.count < 200, CueLog.notable.contains(tag) else { return }
                    let text = rest.dropFirst(tag.count).drop { $0 == " " }
                    notable.append(Line(id: index, time: time, tag: tag, text: String(text)))
                }
                return Session(url: url, started: started, bytes: size(url), ended: ended,
                               notable: notable, isCurrent: url == current)
            }
        }.value
    }
}

/// Serves the log over the LAN as plain text, on :8123, read-only.
///
///     curl http://<ip>:8123/            the sessions, and these routes
///     curl http://<ip>:8123/log         this session
///     curl http://<ip>:8123/log?days=2  every session of the last 2 days
///     curl http://<ip>:8123/log?session=2026-11-20%2014-03-22
///     curl http://<ip>:8123/live        levels and events as they happen
///     curl http://<ip>:8123/mark?froze  a MARK line from the Mac
@MainActor
final class LogServer {
    static let shared = LogServer()

    private static let port: UInt16 = 8123
    private var listener: NWListener?

    func start() {
        guard ProbeGate.isEnabled else { return }
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: port) else { return }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, _, _ in
                let head = chunk.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let parts = target.split(separator: "?", maxSplits: 1)
                let path = parts.first.map(String.init) ?? "/"
                let query = parts.count > 1 ? String(parts[1]) : ""
                Task { @MainActor in Self.route(path, query, on: connection) }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func value(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.first.map(String.init) == name else { continue }
            return kv.count > 1 ? String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding : ""
        }
        return nil
    }

    private static func route(_ path: String, _ query: String, on connection: NWConnection) {
        switch path {
        case "/live": stream(on: connection, eventsOnly: false)
        case "/events": stream(on: connection, eventsOnly: true)
        case "/mark":
            let note = query.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? query
            PlayerProbe.event(CueLog.markTag, "marked from the Mac: \(note.isEmpty ? "mark" : note)")
            sendText(on: connection, "marked: \(note)\n")
        case "/census":
            let text = MemoryCensus.report()
            PlayerProbe.event("mem", text.replacingOccurrences(of: "\n", with: " | "))
            sendText(on: connection, text + "\n")
        case "/writes":
            sendText(on: connection, DiskWrites.report() + "\n")
        case "/health":
            sendText(on: connection, PlayerProbe.healthLines().joined(separator: "\n") + "\n")
        case "/probe":
            sendText(on: connection, PlayerProbe.levels().joined(separator: "\n") + "\n\n"
                + PlayerProbe.events(since: 0, limit: 120).lines.joined(separator: "\n") + "\n")
        case "/log":
            let files = CueLog.files()
            var chosen: [URL]
            if let days = value("days", in: query).flatMap(Double.init) {
                let since = Date().addingTimeInterval(-days * 86_400)
                chosen = files.filter { (CueLog.started($0) ?? .distantPast) >= since }.reversed()
            } else if let session = value("session", in: query) {
                chosen = files.filter { $0.lastPathComponent.hasPrefix(session) }
            } else {
                chosen = CueLog.current.map { [$0] } ?? []
            }
            DispatchQueue.global(qos: .utility).async {
                var body = Data()
                for url in chosen {
                    body.append(Data("==== \(url.deletingPathExtension().lastPathComponent) ====\n".utf8))
                    body.append((try? Data(contentsOf: url)) ?? Data())
                }
                send(on: connection, body.isEmpty ? Data("no log\n".utf8) : body)
            }
        default:
            let list = CueLog.files().map {
                "  \($0.deletingPathExtension().lastPathComponent)   "
                    + ByteCountFormatter.string(fromByteCount: CueLog.size($0), countStyle: .file)
            }
            sendText(on: connection, """
            Cue log — \(PlayerProbe.buildStamp)
              /log              this session
              /log?days=2       the last 2 days
              /log?session=<name>
              /live  /events    as it happens
              /mark?<note>      a MARK line

            sessions:
            \(list.joined(separator: "\n"))

            """)
        }
    }

    /// This Apple TV's address on the LAN, for Settings.
    nonisolated static var address: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            found = String(cString: host)
            if name == "en0" { break }
        }
        return found.map { "\($0):\(port)" }
    }

    /// Live tail: no Content-Length, it never ends; `curl` prints it as it
    /// arrives. Events at once, levels every 2 s.
    private static func stream(on connection: NWConnection, eventsOnly: Bool) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let banner = "=== cue live — \(eventsOnly ? "events" : "levels + events") ===\n"
        connection.send(content: Data(head.utf8) + Data(banner.utf8), completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            Task { @MainActor in tick(on: connection, since: 0, eventsOnly: eventsOnly, ticks: 0) }
        })
    }

    private static func tick(on connection: NWConnection, since: UInt64, eventsOnly: Bool, ticks: Int) {
        var body = ""
        let fresh = PlayerProbe.events(since: since)
        if !fresh.lines.isEmpty { body += fresh.lines.joined(separator: "\n") + "\n" }
        if !eventsOnly, ticks % 4 == 0 {
            let stamp = String(format: "%8.3f", Date().timeIntervalSince(PlayerProbe.startedAt))
            body += "\n\(stamp)  ---- levels ----\n" + PlayerProbe.levels().joined(separator: "\n") + "\n\n"
        }
        let next = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in tick(on: connection, since: fresh.next, eventsOnly: eventsOnly, ticks: ticks + 1) }
            }
        }
        guard !body.isEmpty else { return next() }
        connection.send(content: Data(body.utf8), completion: .contentProcessed { error in
            if error != nil { connection.cancel() } else { next() }
        })
    }

    private static func sendText(on connection: NWConnection, _ text: String) {
        send(on: connection, Data(text.utf8))
    }

    nonisolated private static func send(on connection: NWConnection, _ body: Data) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// The main thread's watchdog and the app's pulse, into the log.
///
/// - A main thread stuck past a second: a HANG line when it comes back, with
///   how long ("stuck 1.4 s"), and one at 5 s in case it never does. The beat
///   is stamped on main; a utility queue only reads how stale it is.
/// - Every 10 s in the foreground a `tick` line: memory, CPU, thermal state.
/// - The lifecycle (active, background…) and memory warnings, at once: the
///   state the app went away in is what the next launch reads (`CueLog`).
enum Watchdog {
    private static let beat: TimeInterval = 0.25
    private static let check: TimeInterval = 0.5
    private static let hangAfter: TimeInterval = 1
    private static let tickEvery: TimeInterval = 10

    private static let queue = DispatchQueue(label: "cue.watchdog", qos: .utility)
    private static let beatAt = Atomic<TimeInterval>(wrappedValue: CACurrentMediaTime())
    private static let active = Atomic<Bool>(wrappedValue: true)

    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var timers: [DispatchSourceTimer] = []
    /// Only on `queue`.
    nonisolated(unsafe) private static var stuckSince: TimeInterval?
    nonisolated(unsafe) private static var toldOngoing = false
    nonisolated(unsafe) private static var lastTick: TimeInterval = 0

    static func start() {
        guard ProbeGate.isEnabled, !started else { return }
        started = true
        let heart = DispatchSource.makeTimerSource(queue: .main)
        heart.schedule(deadline: .now() + beat, repeating: beat, leeway: .milliseconds(20))
        heart.setEventHandler { beatAt.wrappedValue = CACurrentMediaTime() }
        heart.resume()
        let watch = DispatchSource.makeTimerSource(queue: queue)
        watch.schedule(deadline: .now() + check, repeating: check, leeway: .milliseconds(50))
        watch.setEventHandler { look() }
        watch.resume()
        timers = [heart, watch]
        observeLifecycle()
        MainActor.assumeIsolated { FrameDrops.shared.start() }
        queue.async { CueLog.write("writes", DiskWrites.summary()) }
    }

    private static func look() {
        guard ProbeGate.isEnabled else { return }
        let now = CACurrentMediaTime()
        // Suspended or just back: the beat's age says nothing.
        guard active.wrappedValue else { stuckSince = nil; return }
        let stall = now - beatAt.wrappedValue
        if stall > hangAfter {
            if stuckSince == nil { stuckSince = beatAt.wrappedValue }
            if stall > 5, !toldOngoing {
                toldOngoing = true
                CueLog.write("HANG", String(format: "main thread stuck %.0f s and counting · %.0f MB",
                                            stall, PlayerProbe.footprintMB()))
            }
        } else if let since = stuckSince {
            CueLog.write("HANG", String(format: "main thread stuck %.1f s", beatAt.wrappedValue - since))
            PlayerProbe.count("hang")
            stuckSince = nil
            toldOngoing = false
        }
        if now - lastTick >= tickEvery {
            lastTick = now
            CueLog.write("tick", String(format: "mem %.0f MB · cpu %.0f %% · thermal %@ · dropped %d · disk %.1f MB",
                                        PlayerProbe.footprintMB(), PlayerProbe.cpuPercent(),
                                        AppProbe.thermalLabel(ProcessInfo.processInfo.thermalState),
                                        FrameDrops.takeWindow(), Double(DiskWrites.sample()) / 1e6))
        }
    }

    private static func observeLifecycle() {
        let centre = NotificationCenter.default
        func watch(_ name: Notification.Name, _ label: String, active now: Bool) {
            centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                beatAt.wrappedValue = CACurrentMediaTime()
                active.wrappedValue = now
                AppProbe.life("lifecycle \(label)")
            }
        }
        watch(UIApplication.didBecomeActiveNotification, "active", active: true)
        watch(UIApplication.willResignActiveNotification, "inactive", active: false)
        watch(UIApplication.didEnterBackgroundNotification, "background", active: false)
        centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            queue.async { DiskWrites.sample(save: true) }
        }
        watch(UIApplication.willEnterForegroundNotification, "foreground", active: false)
    }
}

/// Frames the main thread missed, for the Log: a display link (as the
/// Frame Rate overlay's), each stretch of dropped frames one DROP line —
/// how many, over how long, the worst frame, the screen and the last press
/// before it — and the 10 s `tick` the window's count. Only the main
/// thread's frames: the GPU's drops need Instruments.
@MainActor
final class FrameDrops {
    static let shared = FrameDrops()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private let frame = 1 / Double(UIScreen.main.maximumFramesPerSecond)
    /// The stretch going on: from its first dropped frame until 0.5 s
    /// without one.
    private var stretchStart: CFTimeInterval?
    private var stretchLastDrop: CFTimeInterval = 0
    private var stretchDropped = 0
    private var stretchWorst: CFTimeInterval = 0
    private var stretchPress: String?
    /// For the tick, read off the watchdog's queue.
    private static let window = Atomic<Int>(wrappedValue: 0)
    nonisolated static func takeWindow() -> Int {
        var count = 0
        window.mutate { count = $0; $0 = 0 }
        return count
    }

    func start() {
        guard link == nil, ProbeGate.isEnabled else { return }
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // Back from the background, the first interval is the time away.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.last = 0 }
        }
    }

    private final class Ticker: NSObject {
        weak var owner: FrameDrops?
        init(_ owner: FrameDrops) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { owner?.tick(link.timestamp) } }
    }

    private func tick(_ now: CFTimeInterval) {
        defer { last = now }
        guard last > 0, ProbeGate.isEnabled else { return }
        let length = now - last
        // A second or more is a hang (the watchdog's) or a pause.
        guard length < 1 else { endStretch(); return }
        let dropped = max(0, Int((length / frame).rounded()) - 1)
        if dropped > 0 {
            Self.window.mutate { $0 += dropped }
            if stretchStart == nil {
                stretchStart = last
                stretchPress = Self.pressSince(last)
            }
            stretchDropped += dropped
            stretchWorst = max(stretchWorst, length)
            stretchLastDrop = now
        } else if stretchStart != nil, now - stretchLastDrop > 0.5 {
            endStretch()
        }
    }

    private func endStretch() {
        guard let start = stretchStart else { return }
        defer { stretchStart = nil; stretchDropped = 0; stretchWorst = 0; stretchPress = nil }
        // One lost frame on its own is noise.
        guard stretchDropped >= 2 else { return }
        let span = stretchLastDrop - start
        CueLog.write("DROP", String(format: "%d frames in %.2f s, worst %.0f ms · %@%@",
                                    stretchDropped, span, stretchWorst * 1000, AppProbe.place,
                                    stretchPress.map { " · " + $0 } ?? ""))
    }

    /// The last press, if it came within a second of `time`.
    private static func pressSince(_ time: CFTimeInterval) -> String? {
        let ago = time - InputHold.lastPress
        guard InputHold.lastPress > 0, ago < 1 else { return nil }
        return String(format: "%@ %.2f s before", InputHold.lastPressName, max(0, ago))
    }
}

/// Everything the player probe never reached: browsing, focus, data loads,
/// sync and app lifecycle.
///
/// The player has been watchable over `:8123` since 2026-09-08; the rest of
/// the app had no instrumentation at all, so "it got stuck while I was moving
/// around" had nothing behind it but a guess. This is the SAME bus — one ring,
/// one clock, one `/live` tail — with app-shaped verbs, so a browse and the
/// playback it leads into read as one story instead of two.
///
/// Gated by `ProbeGate`, not by the compiler: with capture off the message is
/// never built (it is an `@autoclosure` behind a cheap flag check), so the call
/// sites are still free to sit anywhere, including in a `body`. With capture on
/// — the Settings toggle in a Release/sideloaded build — they all record.
///
/// Lives in this file for the same reason `PlayerProbe` does — `project.yml`
/// globs sources but the checked-in `.xcodeproj` does not, so a NEW file needs
/// an xcodegen run. See [[nuviotv-device-debugging]].
enum AppProbe {

    // MARK: Verbs
    //
    // One tag per concern rather than a single "app" tag: the live tail is
    // read by eye, and `grep -w focus` on a recording is the difference
    // between finding a focus bug and scrolling past it.

    /// Screens appearing and leaving, tab switches, pushes and pops.
    nonisolated static func nav(_ line: @autoclosure () -> String) {
        PlayerProbe.event("nav", line())
    }

    /// Anything that moves focus or refuses to: the rail, the focus router,
    /// the enable/disable windows. The app's most-repaired area by far.
    nonisolated static func focus(_ line: @autoclosure () -> String) {
        PlayerProbe.event("focus", line())
    }

    /// Catalogs, collections, add-on manifests, metadata, artwork — what was
    /// asked for, how long it took, and what came back.
    nonisolated static func data(_ line: @autoclosure () -> String) {
        PlayerProbe.event("data", line())
    }

    /// The account sync and everything it writes.
    nonisolated static func sync(_ line: @autoclosure () -> String) {
        PlayerProbe.event("sync", line())
    }

    /// Launch, foreground, background, memory pressure.
    nonisolated static func life(_ line: @autoclosure () -> String) {
        PlayerProbe.event("life", line())
    }

    /// Something went wrong, whether or not the viewer noticed.
    ///
    /// Logged AND counted AND kept as the latest note, because the three
    /// answer different questions: the event says when, the counter says how
    /// often (a failure that fires once is a blip; the same one forty times is
    /// the bug), and the note survives past the end of the ring so a long
    /// session still reports its last failure.
    nonisolated static func warn(_ area: String, _ line: @autoclosure () -> String) {
        guard ProbeGate.isEnabled else { return }
        let text = line()
        PlayerProbe.event("WARN", "\(area): \(text)")
        PlayerProbe.count("warn.\(area)")
        PlayerProbe.note("lastWarn", "\(area): \(text)")
    }

    /// Stopwatch for anything that takes time. Returns the closure that ends
    /// it; call it with a one-word outcome.
    ///
    ///     let done = AppProbe.begin("data", "catalog \(name)")
    ///     …
    ///     done("\(items.count) items")
    ///
    /// Anything past two seconds also bumps a counter, so "it felt slow" has a
    /// number behind it without anyone having to have been watching the tail
    /// at the time.
    nonisolated static func begin(_ tag: String, _ what: String) -> (String) -> Void {
        guard ProbeGate.isEnabled else { return { _ in } }
        let started = CACurrentMediaTime()
        PlayerProbe.event(tag, what + " …")
        return { outcome in
            let ms = (CACurrentMediaTime() - started) * 1000
            PlayerProbe.event(tag, String(format: "%@ — %.0fms · %@", what, ms, outcome))
            if ms > 2000 { PlayerProbe.count("slow.\(tag)") }
        }
    }

    /// A URL boiled down to what identifies it in a log: host plus the part of
    /// the path that says what was asked for, with the token query an add-on
    /// carries dropped. Full URLs are 200 characters of noise, and several of
    /// them contain credentials.
    nonisolated static func requestName(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let host = url.host ?? "?"
        var path = url.path
        if path.hasSuffix(".json") { path.removeLast(5) }
        // Add-on paths are `/…config…/resource/type/id`; the resource is what
        // matters and the config in front of it can be enormous.
        for resource in ["/catalog/", "/meta/", "/stream/", "/subtitles/"] where path.contains(resource) {
            if let r = path.range(of: resource) { path = String(path[r.lowerBound...]) }
            break
        }
        if path.count > 80 { path = String(path.prefix(80)) + "…" }
        return host + path
    }

    // MARK: The [app] block

    /// What is on screen right now. Fed by `RootView` and `probeScreen`, read
    /// by the sampler below.
    ///
    /// Held here rather than sampled out of `RootView` because a sampler that
    /// captures a SwiftUI `View` reads whatever that struct's snapshot held,
    /// and a stale tab number in the one block meant to orient the reader is
    /// worse than no block.
    @MainActor static var tab = "—"
    @MainActor static var screen = "—"
    @MainActor static var rail = "—"
    @MainActor static var scene = "active"

    /// Screens currently mounted, innermost last — a pushed Detail over Home
    /// reads as `Home › Detail`, which is the question "where am I" answered
    /// without inferring it from a stream of appear/disappear events.
    @MainActor private static var mounted: [String] = []

    @MainActor static func entered(screen name: String, _ detail: String) {
        mounted.append(name)
        screen = name
        nav("→ \(name)" + (detail.isEmpty ? "" : "  \(detail)") + "   [\(breadcrumb)]")
    }

    @MainActor static func left(screen name: String, after seconds: TimeInterval) {
        if let i = mounted.lastIndex(of: name) { mounted.remove(at: i) }
        screen = mounted.last ?? "—"
        nav(String(format: "← %@ after %.1fs   [%@]", name, seconds, breadcrumb))
    }

    /// Where you are: the tab, and the page over it if one is (every tab's
    /// root stays mounted once built, so the breadcrumb lists them all).
    @MainActor static var place: String {
        let roots: Set<String> = ["Home", "Search", "Library", "Settings", "Discover", "Upcoming"]
        guard let top = mounted.last, !roots.contains(top) else { return tab }
        return tab + " › " + top
    }

    @MainActor static var breadcrumb: String {
        mounted.isEmpty ? "—" : mounted.joined(separator: " › ")
    }

    /// How deep the push stack is, counted off the mounted screens rather than
    /// a `NavigationPath` — there are five independent paths, one per tab, and
    /// keeping five counters in step is a bug waiting to be written.
    @MainActor static var depth: Int { max(mounted.count - 1, 0) }

    /// Thermal pressure, the one OS signal that explains "it only stutters
    /// after twenty minutes" without anything in the app having changed.
    nonisolated static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "?"
        }
    }

    /// One-line output-route summary. Route changes are a classic source of
    /// dropouts and A/V drift ("it went out of sync when the soundbar woke"),
    /// and nothing else in the app records them.
    @MainActor static var audioRouteLabel: String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        return (outputs.isEmpty ? "—" : outputs.joined(separator: ","))
            + "  cat=\(session.category.rawValue)/\(session.mode.rawValue)"
    }

    /// Register the `[app]` level block. Called once, from the app's `init`,
    /// so browsing is observable before anything has been played.
    @MainActor static func installLevels() {
        // Pin the probe clock at LAUNCH. `PlayerProbe.startedAt` is lazy, so
        // without this it was first touched when a client read the log —
        // making every event logged before that read show a NEGATIVE time.
        _ = PlayerProbe.startedAt
        PlayerProbe.register("app") {
            [
                "tab=\(tab)  screen=\(screen)  depth=\(depth)  scene=\(scene)",
                "where=\(breadcrumb)",
                "rail=\(rail)  lastFocusedRow=\(ContentFocusRouter.shared.lastRowID ?? "—")",
                "thermal=\(thermalLabel(ProcessInfo.processInfo.thermalState))"
                    + "  lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled.probe)"
                    + "  cpus=\(ProcessInfo.processInfo.activeProcessorCount)",
                "mem=\(String(format: "%.0fMB", PlayerProbe.footprintMB()))",
                "audio=\(audioRouteLabel)",
            ]
        }
        // A jetsam on a 3 GB box is preceded by this, and "the app just
        // closed" is otherwise indistinguishable from a crash after the fact.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            warn("memory", String(format: "memory warning at %.0fMB", PlayerProbe.footprintMB()))
        }
        // Thermal throttling and audio-route changes both show up as "it just
        // started stuttering / drifted" with nothing in the player log.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            life("thermal → \(thermalLabel(ProcessInfo.processInfo.thermalState))")
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            guard ProbeGate.isEnabled else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            Task { @MainActor in
                life("audio route → \(audioRouteLabel)  reason=\(reason.map(String.init(describing:)) ?? "?")")
            }
        }
        life("probe armed — app block registered")
    }
}

/// Logs a screen's appear and disappear, and keeps `[app]`'s "where" current.
///
/// A modifier rather than two hand-written `onAppear`/`onDisappear` pairs per
/// screen: the pair has to agree on the name and on the clock, and thirty
/// hand-written pairs would not. It adds no layout and no state of its own
/// beyond the entry timestamp.
private struct ProbeScreen: ViewModifier {
    let name: String
    let detail: () -> String
    @State private var shownAt = Date()

    func body(content: Content) -> some View {
        content
            .onAppear {
                shownAt = Date()
                AppProbe.entered(screen: name, detail())
            }
            .onDisappear {
                AppProbe.left(screen: name, after: Date().timeIntervalSince(shownAt))
            }
    }
}

extension View {
    /// Mark this view as a screen for the `[app]` probe block.
    ///
    /// `detail` is a closure so it is evaluated once per appearance rather
    /// than on every body pass — several of these read a title or a count off
    /// a model that is being rebuilt continuously.
    func probeScreen(_ name: String, _ detail: @escaping () -> String = { "" }) -> some View {
        modifier(ProbeScreen(name: name, detail: detail))
    }
}

/// What Cue writes to the box's flash, to watch wear (`/writes` on the log
/// server, a `writes` line at launch, the tick's "disk"): the kernel's own
/// count of the process's bytes written to disk (`proc_pid_rusage`), so the
/// player's segments, pictures, logs and the rest alike, split by whether
/// the player is up; per day for 400 days in the defaults, saved every
/// 15 min and on going to the background (a death loses at most that).
enum DiskWrites {
    private static let key = "cue.diskWrites"
    private static let keepDays = 400
    private static let saveEvery: TimeInterval = 900
    private static let lock = NSLock()
    nonisolated(unsafe) private static var playing = false
    nonisolated(unsafe) private static var last: UInt64?
    nonisolated(unsafe) private static var lastSave: TimeInterval = 0
    /// Day ("2026-11-27") → [player, other] bytes.
    nonisolated(unsafe) private static var days: [String: [Int64]] = [:]
    nonisolated(unsafe) private static var since = ""
    nonisolated(unsafe) private static var loaded = false

    @_silgen_name("proc_pid_rusage")
    private static func rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

    private static func written() -> UInt64? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { rusage(getpid(), RUSAGE_INFO_V4, $0) }
        return ok == 0 ? info.ri_diskio_byteswritten : nil
    }

    private static func today() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Only under `lock`.
    private static func loadOnce() {
        guard !loaded else { return }
        loaded = true
        let stored = UserDefaults.standard.dictionary(forKey: key)
        since = stored?["since"] as? String ?? today()
        for (day, value) in stored?["days"] as? [String: [NSNumber]] ?? [:] where value.count == 2 {
            days[day] = value.map(\.int64Value)
        }
    }

    /// Adds what was written since the last look to today; the bytes added.
    @discardableResult
    static func sample(save force: Bool = false) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        loadOnce()
        guard let now = written() else { return 0 }
        defer { last = now }
        let delta = last.map { now >= $0 ? Int64(now - $0) : Int64(now) } ?? Int64(now)
        if delta > 0 {
            var entry = days[today()] ?? [0, 0]
            entry[playing ? 0 : 1] += delta
            days[today()] = entry
        }
        let clock = CACurrentMediaTime()
        if force || clock - lastSave >= saveEvery {
            lastSave = clock
            let kept = days.keys.sorted().suffix(keepDays)
            days = days.filter { kept.contains($0.key) }
            UserDefaults.standard.set(["since": since, "days": days], forKey: key)
        }
        return delta
    }

    /// The player came up or went: what came before counts to the old side.
    static func player(up: Bool) {
        sample()
        lock.lock(); playing = up; lock.unlock()
    }

    static func report() -> String {
        sample()
        lock.lock(); defer { lock.unlock() }
        func gb(_ b: Int64) -> String { b < 1_000_000_000 ? "\(b / 1_000_000) MB" : String(format: "%.1f GB", Double(b) / 1e9) }
        let sorted = days.keys.sorted()
        let player = days.values.reduce(0) { $0 + $1[0] }
        let other = days.values.reduce(0) { $0 + $1[1] }
        let count = max(1, sorted.count)
        var lines = ["since \(since) · \(sorted.count) days with the app run · \(gb(player + other)) "
            + "(playback \(gb(player)), the rest \(gb(other))) · \(gb((player + other) / Int64(count))) a day on those days"]
        var months: [String: [Int64]] = [:]
        for day in sorted {
            let month = String(day.prefix(7))
            var m = months[month] ?? [0, 0]
            m[0] += days[day]![0]; m[1] += days[day]![1]
            months[month] = m
        }
        lines.append("")
        for month in months.keys.sorted() {
            let m = months[month]!
            lines.append("\(month)  \(gb(m[0] + m[1]))  playback \(gb(m[0]))  rest \(gb(m[1]))")
        }
        lines.append("")
        for day in sorted.suffix(31) {
            let d = days[day]!
            lines.append("\(day)  \(gb(d[0] + d[1]))  playback \(gb(d[0]))  rest \(gb(d[1]))")
        }
        return lines.joined(separator: "\n")
    }

    static func summary() -> String { report().split(separator: "\n").first.map(String.init) ?? "" }
}

/// What the views hold in decoded pictures (`/census` on the log server):
/// every window's views and layers, each picture counted once, on screen or
/// not, grouped by the cell or view that holds it. Against the footprint it
/// says whether memory is pictures in views, or somewhere else.
@MainActor
enum MemoryCensus {
    static func report() -> String {
        var seen = Set<ObjectIdentifier>()
        var shown = 0, hidden = 0
        var owners: [String: (count: Int, bytes: Int)] = [:]
        let screen = UIScreen.main.bounds
        func bytes(_ image: CGImage) -> Int { image.bytesPerRow * image.height }
        func owner(_ view: UIView) -> String {
            var current: UIView? = view
            while let v = current {
                if v is UICollectionViewCell || v is UITableViewCell { return String(describing: type(of: v)) }
                current = v.superview
            }
            return String(describing: type(of: view))
        }
        func visit(_ layer: CALayer, view: UIView, visible: Bool, parked: Bool) {
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image = contents as! CGImage
                if seen.insert(ObjectIdentifier(image)).inserted {
                    let size = bytes(image)
                    if visible { shown += size } else { hidden += size }
                    let key = owner(view) + (visible ? "" : parked ? " (hidden)" : " (off screen)")
                    owners[key, default: (0, 0)].count += 1
                    owners[key, default: (0, 0)].bytes += size
                }
            }
            for sub in layer.sublayers ?? [] where sub.delegate == nil { visit(sub, view: view, visible: visible, parked: parked) }
        }
        func walk(_ view: UIView, visible: Bool, hiddenAbove: Bool = false) {
            let frame = view.convert(view.bounds, to: nil)
            let on = visible && !view.isHidden && view.alpha > 0.01 && frame.intersects(screen)
            let isHidden = hiddenAbove || view.isHidden
            if let imageView = view as? UIImageView, let image = imageView.image?.cgImage,
               seen.insert(ObjectIdentifier(image)).inserted {
                let size = bytes(image)
                if on { shown += size } else { hidden += size }
                let key = owner(view) + (on ? "" : isHidden ? " (hidden)" : " (off screen)")
                owners[key, default: (0, 0)].count += 1
                owners[key, default: (0, 0)].bytes += size
            }
            visit(view.layer, view: view, visible: on, parked: isHidden)
            for sub in view.subviews { walk(sub, visible: on, hiddenAbove: isHidden) }
        }
        var windows = 0
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                windows += 1
                walk(window, visible: !window.isHidden)
            }
        }
        let mb = { (b: Int) in String(format: "%.0f MB", Double(b) / 1_048_576) }
        var lines = [
            "footprint \(String(format: "%.0f MB", PlayerProbe.footprintMB())) · pictures in views \(mb(shown + hidden))"
                + " (on screen \(mb(shown)), off screen or hidden \(mb(hidden))) · \(windows) windows",
            "image cache \(mb(ImageCache.shared.memoryCost)) of \(mb(PerformanceProfile.imageCacheBytes))"
                + { let d = ImageCache.shared.duplicates
                    return d.pictures > 0 ? " · \(d.pictures) at two sizes or more, \(mb(d.bytes)) in the extra copies" : "" }(),
        ]
        lines += ImageCache.shared.duplicateSizes.prefix(12).map { "  twice: " + $0 }
        for (key, value) in owners.sorted(by: { $0.value.bytes > $1.value.bytes }).prefix(20) {
            lines.append("  \(mb(value.bytes).padding(toLength: 8, withPad: " ", startingAt: 0)) \(value.count) × \(key)")
        }
        return lines.joined(separator: "\n")
    }
}
