import Foundation

/// The row that last held focus in the page, for the probe's focus lines
/// (`AppProbe`). (It also handed focus from the old side rail back to that
/// row's first card; the top bar leaves focus to the engine now.)
@MainActor
final class ContentFocusRouter {
    static let shared = ContentFocusRouter()

    /// The row that last held focus in the content.
    private(set) var lastRowID: String?

    /// A tile in `rowID` just took focus.
    func noteFocused(row rowID: String) {
        // Only the CHANGES: a row notes itself on every tile the viewer moves
        // to, and a tail of "still in row 3" forty times over is noise that
        // pushes the useful lines out of the ring.
        if lastRowID != rowID {
            AppProbe.focus("content focus: \(lastRowID ?? "—") → \(rowID)")
        }
        lastRowID = rowID
    }
}
