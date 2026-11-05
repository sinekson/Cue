import Foundation

/// What was picked by hand in the player for a title (a show for all its
/// episodes): replayed the next time it plays, over Settings → Playback.
/// Defaults and automatic picks never write here.
struct TitleMemory: Codable {
    /// The audio's language (ISO 639-1 where known).
    var audioLanguage: String?
    /// The subtitles' language, or "off" for an explicit off choice.
    var subtitleLanguage: String?
    /// The forced track of that language ("Signs & Songs"), not the full one.
    var subtitleForced: Bool?
    var updatedAt = Date()
}

enum PlaybackMemory {
    private static let key = "cue.player.titleMemory.v1"
    private static let limit = 200

    /// In-process mirror of the stored table (this process is its only writer).
    private nonisolated(unsafe) static var mirror: [String: TitleMemory]?
    private static let mirrorLock = NSLock()

    private static func loadAll() -> [String: TitleMemory] {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        if let mirror { return mirror }
        let decoded = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: TitleMemory].self, from: $0) } ?? [:]
        mirror = decoded
        return decoded
    }

    private static func saveAll(_ all: [String: TitleMemory]) {
        var all = all
        // Bound by recency, so a big library can't grow this without limit.
        if all.count > limit {
            let keep = all.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(limit)
            all = Dictionary(uniqueKeysWithValues: Array(keep))
        }
        mirrorLock.lock()
        mirror = all
        mirrorLock.unlock()
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func memory(for metaID: String) -> TitleMemory? { loadAll()[metaID] }

    static func update(_ metaID: String, _ mutate: (inout TitleMemory) -> Void) {
        var all = loadAll()
        var entry = all[metaID] ?? TitleMemory()
        mutate(&entry)
        entry.updatedAt = Date()
        all[metaID] = entry
        saveAll(all)
    }
}
