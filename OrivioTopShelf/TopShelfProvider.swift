import TVServices

/// Top Shelf: shows the app's Continue Watching row on the tvOS home screen
/// when OrivioTV sits in the dock's top row — the tvOS equivalent of Android
/// TV's "Watch Next" channel.
///
/// Data flows one way: the app exports a small JSON snapshot of the Continue
/// Watching list into the shared app-group container every time progress
/// changes (see TopShelfExporter); this extension just reads and renders it.
/// Selecting an item deep-links into the app via orivio://meta?type=…&id=…
/// (handled by DeepLinkService), which opens the title's detail page.
///
/// If the app group isn't available (e.g. a sideload signer that strips the
/// entitlement), the container URL is nil and the shelf simply stays empty —
/// the app itself is unaffected.
final class TopShelfProvider: TVTopShelfContentProvider {

    /// Mirror of TopShelfExporter.Entry — kept as its own tiny struct so the
    /// extension target doesn't need to compile any app sources.
    private struct Entry: Codable {
        let id: String
        let type: String
        let title: String
        let subtitle: String?
        let imageURL: String?
        var progress: Double? = nil
        var caption: String? = nil
    }

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        completionHandler(Self.content())
    }

    /// Crunchyroll layout: Continue Watching first — its most recent title as
    /// a wide 16:9 card, the rest as portrait posters — then the Library as
    /// portrait posters. Either may be empty; with both empty there's no
    /// shelf at all.
    ///
    /// `mixShapesInOneSection`: true puts the wide card and the posters in
    /// ONE "Continue Watching" section. If tvOS draws mixed shapes badly on
    /// your box, set it to false: the wide card then gets its own section
    /// and the remaining Continue Watching posters follow in an untitled one.
    private static let mixShapesInOneSection = true
    private static func content() -> TVTopShelfContent? {
        // Written by the app beside the snapshots — see TopShelfExporter.
        let scheme = AppGroupResolver.sharedFile("topshelf-scheme.txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "orivio"

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        let continueEntries = load("topshelf.json")
        if !continueEntries.isEmpty {
            let items = continueEntries.enumerated().map { index, entry -> TVTopShelfSectionedItem in
                // The app pre-renders these cards (art + progress pill), so
                // the image already has the right shape and its own bar.
                let item = makeItem(entry, scheme: scheme, shape: index == 0 ? .hdtv : .poster)
                // Just the episode title (the movie's name for a movie).
                item.title = entry.caption ?? entry.title
                // Only when the app couldn't render a card: system bar.
                if let progress = entry.progress { item.playbackProgress = progress }
                return item
            }
            if mixShapesInOneSection || items.count == 1 {
                let section = TVTopShelfItemCollection(items: items)
                section.title = "Continue Watching"
                sections.append(section)
            } else {
                let wide = TVTopShelfItemCollection(items: [items[0]])
                wide.title = "Continue Watching"
                sections.append(wide)
                sections.append(TVTopShelfItemCollection(items: Array(items.dropFirst())))
            }
        }

        let libraryEntries = load("topshelf-library.json")
        if !libraryEntries.isEmpty {
            let items = libraryEntries.map { makeItem($0, scheme: scheme, shape: .poster) }
            let section = TVTopShelfItemCollection(items: items)
            section.title = "Library"
            sections.append(section)
        }

        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }

    private static func load(_ fileName: String) -> [Entry] {
        // AppGroupResolver is shared with the app target (see project.yml) so
        // both sides resolve the SAME signer-assigned group at runtime.
        guard let file = AppGroupResolver.sharedFile(fileName),
              let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    /// One card: image, shape, and a deep link into the title's detail page.
    private static func makeItem(_ entry: Entry, scheme: String,
                                 shape: TVTopShelfSectionedItem.ImageShape) -> TVTopShelfSectionedItem {
        // Identifier scoped by shape: a title can be in both sections.
        let item = TVTopShelfSectionedItem(identifier: "\(shape.rawValue)|\(entry.id)")
        item.title = entry.title
        item.imageShape = shape
        if let urlString = entry.imageURL, let url = URL(string: urlString) {
            item.setImageURL(url, for: [.screenScale1x, .screenScale2x])
        }
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "meta"
        comps.queryItems = [
            URLQueryItem(name: "type", value: entry.type),
            URLQueryItem(name: "id", value: entry.id)
        ]
        if let url = comps.url {
            item.displayAction = TVTopShelfAction(url: url)
            item.playAction = TVTopShelfAction(url: url)
        }
        return item
    }
}


private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
