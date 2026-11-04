import SwiftUI

/// The stage: the title's backdrop, the logo or name over it.
/// Every way into the player goes through it, from the press until the film's
/// first frame has come up over it. The root shows it while `scene` is set.
@MainActor
final class PlayStage: ObservableObject {
    static let shared = PlayStage()

    /// Coming up, slower than a page's fade: the room going dark before a film.
    nonisolated static let fadeIn: Animation = .easeInOut(duration: 0.7)

    struct Scene: Equatable {
        let title: String
        /// Blurred and dimmed: an episode's still, else TMDB's backdrop, as
        /// Details' and the billboard's.
        var art: String?
        let logo: String?
        /// A show's episode: its name, and "Season 2, Episode 5".
        let episodeName: String?
        let episodeNumber: String?
        /// What it says while it works: one line of each set per press.
        let searchingLine: String
        let startingLine: String
    }

    /// Past the plain search and start.
    enum Note: Equatable {
        /// A link failed before its first frame: the next is tried.
        case swapping
        /// Every link tried failed (this many): the list is up to pick another.
        case allFailed(tried: Int)
    }

    static let searchingLines = ["Finding a print", "Finding a good copy", "Checking under the couch"]
    static let startingLines = ["Lights down", "Shh, it's starting", "Curtain up"]
    static let swappingLine = "Swapping reels"
    static func allFailedLine(tried: Int) -> String {
        switch tried {
        case 1: "That one wouldn't play. Pick another."
        case 2: "The first two wouldn't play. Pick another."
        // A list searched again on the way: not just the first ones.
        default: "These wouldn't play. Pick another."
        }
    }
    static let nothingFoundLine = "No prints anywhere. Try Refresh in a bit."

    @Published private(set) var scene: Scene?
    @Published var note: Note?

    func show(_ meta: MetaItem, _ video: MetaVideo?, art: String? = nil) {
        let same = scene?.title == meta.name
        var name = same ? scene?.episodeName : nil, number = same ? scene?.episodeNumber : nil
        if let video, let season = video.season, let episode = video.episode {
            name = video.title.flatMap { $0.isEmpty ? nil : $0 }
            number = "\(season == 0 ? "Specials" : "Season \(season)"), Episode \(episode)"
        }
        // A TMDB still in full size; an add-on's thumbnail is often too small.
        let still = video?.thumbnail.flatMap { $0.contains("image.tmdb.org") ? TMDBService.originalSize($0) : nil }
        let known = art ?? still ?? (same ? scene?.art : nil)
        if !same { note = nil }
        scene = Scene(title: meta.name, art: known,
                      logo: meta.logo ?? (same ? scene?.logo : nil) ?? BillboardPicks.metaHubLogo(meta.id),
                      episodeName: name, episodeNumber: number,
                      searchingLine: same ? scene?.searchingLine ?? Self.pick(Self.searchingLines, not: nil)
                          : Self.pick(Self.searchingLines, not: scene?.searchingLine ?? lastSearching),
                      startingLine: same ? scene?.startingLine ?? Self.pick(Self.startingLines, not: nil)
                          : Self.pick(Self.startingLines, not: scene?.startingLine ?? lastStarting))
        lastSearching = scene?.searchingLine
        lastStarting = scene?.startingLine
        artTask?.cancel()
        guard known == nil else { return }
        // Not handed one (a card's hold menu): TMDB's backdrop, as Details
        // shows it; the card's own background only where TMDB has none or
        // takes too long. Never the poster (a smear, stretched to 16:9).
        let fallback = meta.background
        artTask = Task { [weak self] in
            let found = await Self.backdrop(meta)
            guard !Task.isCancelled, let self, self.scene?.title == meta.name, self.scene?.art == nil else { return }
            self.scene?.art = found ?? fallback
        }
    }

    private var artTask: Task<Void, Never>?
    /// The last press's lines: the next press says something else.
    private var lastSearching: String?
    private var lastStarting: String?

    private static func pick(_ lines: [String], not last: String?) -> String {
        lines.filter { $0 != last }.randomElement() ?? lines[0]
    }

    /// TMDB's backdrop, at most `artWait` (from its cache at once).
    private static func backdrop(_ meta: MetaItem) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await TMDBService.backdrop(id: meta.id, type: meta.type) }
            group.addTask { try? await Task.sleep(for: .seconds(artWait)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static let artWait = 1.5

    func clear() {
        scene = nil
        note = nil
    }
}

/// The source row (`SourcePanel`), on the stage, not tied to a screen:
/// Details opens it (hold Play; Play finding nothing), Continue Watching too
/// ("Choose Source"). The root shows it while `request` is set and plays
/// what's picked; `picked` while that loads, the list hidden, for Back to
/// come back to.
@MainActor
final class SourcePicker: ObservableObject {
    static let shared = SourcePicker()

    struct Request: Identifiable {
        let id = UUID()
        let meta: MetaItem
        let video: MetaVideo?
        /// Play the pick from the start (else from the saved position).
        var fromStart = false
    }

    @Published private(set) var request: Request?
    @Published var picked = false
    /// The list has nothing to show yet: the stage waits as for Play.
    @Published var searching = false
    /// The search is done and found nothing.
    @Published var empty = false
    /// Links tried for this title that didn't play (`rejectionKey`), marked
    /// on the list until it closes or Refresh brings new links.
    @Published var failed: Set<String> = []
    /// The stage's holding view has had focus: it goes, and focus falls into
    /// the list (`PlayStageView`).
    @Published var listShown = false

    func open(_ meta: MetaItem, _ video: MetaVideo?, fromStart: Bool = false, art: String? = nil) {
        if request?.meta.id != meta.id || request?.video?.id != video?.id { failed = [] }
        PlayStage.shared.show(meta, video, art: art)
        picked = false
        searching = false
        empty = false
        listShown = false
        request = Request(meta: meta, video: video, fromStart: fromStart)
    }

    func close() {
        request = nil
        picked = false
        searching = false
        empty = false
        failed = []
        listShown = false
        PlayStage.shared.clear()
    }
}
