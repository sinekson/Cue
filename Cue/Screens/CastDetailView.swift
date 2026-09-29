import SwiftUI

@MainActor
final class CastDetailViewModel: ObservableObject {
    @Published var items: [MetaItem] = []
    @Published var isLoading = true

    private var hasLoaded = false

    let personID: Int
    let personName: String

    init(personID: Int, personName: String) {
        self.personID = personID
        self.personName = personName
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        defer { isLoading = false }
        items = await TMDBService.personFilmography(personID: personID)
    }
}

/// An actor's filmography, reached by focusing a cast member on the Detail
/// screen. Mirrors the Android `CastDetailScreen`.
struct CastDetailView: View {
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var viewModel: CastDetailViewModel

    let onSelect: (MetaItem) -> Void

    private let columns = Array(repeating: GridItem(.fixed(220), spacing: CueSpacing.lg), count: 6)

    init(personID: Int, personName: String, onSelect: @escaping (MetaItem) -> Void) {
        _viewModel = StateObject(wrappedValue: CastDetailViewModel(personID: personID, personName: personName))
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack {
            ATVBackground()
            if viewModel.isLoading {
                CueLoadingView(label: "Loading filmography", holdsFocus: true)
            } else if viewModel.items.isEmpty {
                CueEmptyState(
                    icon: "person.fill.questionmark",
                    title: viewModel.personName,
                    message: "No filmography available for this person.",
                    holdsFocus: true
                )
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: CueSpacing.xl) {
                        Text(viewModel.personName)
                            .font(FusionType.pageTitle(theme.font))
                            .foregroundStyle(theme.palette.textPrimary)
                            .padding(.leading, CueSpacing.huge)
                            .padding(.top, CueSpacing.xxl)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: CueSpacing.xl) {
                            ForEach(viewModel.items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    PosterCard(item: item)
                                }
                                .mediaCardButtonStyle()
                            }
                        }
                        .padding(.horizontal, CueSpacing.huge)
                        .padding(.bottom, CueSpacing.huge)
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task { await viewModel.load() }
    }
}
