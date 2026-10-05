import Foundation

/// The source picker (`SourcePanel`), over the whole app — not tied to a
/// screen: Details opens it (hold Play; Play finding nothing), Continue
/// Watching too ("Choose Source"). The root shows it while `request` is set
/// and plays what's picked.
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

    func open(_ meta: MetaItem, _ video: MetaVideo?, fromStart: Bool = false) {
        request = Request(meta: meta, video: video, fromStart: fromStart)
    }

    func close() { request = nil }
}
