import SwiftUI

/// The stage: the screen at the press blurred and dimmed, the logo or name over it.
/// Every way into the player goes through it, from the press until the film's
/// first frame has come up over it. The root shows it while `scene` is set.
@MainActor
final class PlayStage: ObservableObject {
    static let shared = PlayStage()

    /// Coming up, slower than a page's fade: the room going dark before a film.
    nonisolated static let fadeIn: Animation = .easeInOut(duration: 0.7)

    struct Scene: Equatable {
        let title: String
        let logo: String?
        let art: String?
        let episode: String?
    }

    @Published private(set) var scene: Scene?

    func show(_ meta: MetaItem, _ video: MetaVideo?, art: String? = nil) {
        let episode = video.flatMap { video -> String? in
            guard !video.seasonEpisodeCode.isEmpty else { return nil }
            return [video.seasonEpisodeCode, video.title].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let same = scene?.title == meta.name
        scene = Scene(title: meta.name, logo: meta.logo ?? (same ? scene?.logo : nil),
                      art: art ?? (same ? scene?.art : nil) ?? meta.background ?? meta.poster,
                      episode: episode ?? (same ? scene?.episode : nil))
    }

    func clear() { scene = nil }
}

/// The source list (`SourcePanel`), on the stage, not tied to a screen:
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

    func open(_ meta: MetaItem, _ video: MetaVideo?, fromStart: Bool = false, art: String? = nil) {
        PlayStage.shared.show(meta, video, art: art)
        picked = false
        request = Request(meta: meta, video: video, fromStart: fromStart)
    }

    func close() {
        request = nil
        picked = false
        PlayStage.shared.clear()
    }
}
