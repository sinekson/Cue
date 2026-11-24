import SwiftUI
import Combine

/// Settings categories, each a pushed pane on the Settings screen.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case account, tmdb, mdblist, appearance, homeContent, playback, storage, about, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Nuvio"
        case .tmdb: return "TMDB"
        case .mdblist: return "MDBList"
        case .appearance: return "Appearance"
        case .homeContent: return "Home & Details"
        case .playback: return "Playback"
        case .storage: return "Storage"
        case .about: return "About"
        case .developer: return "Developer"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "Keeps your profiles, add-ons and watch progress in sync across your devices."
        case .tmdb: return ServiceKey.tmdb.about
        case .mdblist: return ServiceKey.mdblist.about
        case .appearance: return "Change how Cue's pages and cards look."
        case .homeContent: return "Choose what Home shows and how titles behave."
        case .playback: return "Choose the language titles play in."
        case .storage: return "See what Cue keeps on this Apple TV and clear it."
        case .about: return "See Cue's version, privacy and licenses."
        case .developer: return "Measure the frame rate, inspect playback and keep a log."
        }
    }

    /// Its symbol on Settings' tile, on its pages (the categories: the play).
    var symbol: String {
        switch self {
        case .account: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .tmdb: return "photo.badge.magnifyingglass"
        case .mdblist: return "hand.thumbsup"
        case .appearance: return "paintpalette"
        case .homeContent: return "rectangle.grid.3x1"
        case .playback: return "playpause"
        case .storage: return "internaldrive"
        case .about: return "info.circle"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The accounts and keys, in their own section up top.
    static let accounts: [SettingsCategory] = [.account, .tmdb, .mdblist]
}

// MARK: - Detail scaffolding

/// A rounded, accent-tinted tile holding an SF Symbol. Gives every settings row
/// a consistent, scannable icon "chip" (iOS-Settings style) — the core visual
/// motif of the redesigned panes.
struct SettingsIconTile: View {
    let symbol: String
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [CuePalette.secondary.opacity(0.32), CuePalette.secondary.opacity(0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(CuePalette.secondary.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(CuePalette.secondary)
            )
            .frame(width: size, height: size)
    }
}

/// A tappable settings row with strong focus, matching the Android SettingsActionRow.
struct SettingsActionRow: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    let title: String
    var subtitle: String?
    var value: String?
    var leadingIcon: String?

    var body: some View {
        HStack(spacing: CueSpacing.md) {
            if let leadingIcon {
                SettingsIconTile(symbol: leadingIcon)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(CuePalette.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(CuePalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            Spacer(minLength: CueSpacing.lg)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(CuePalette.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFocused ? CuePalette.textSecondary : CuePalette.textTertiary)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, CueSpacing.md)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity)
        .background(SettingsRowBackground(isFocused: isFocused))
        // Was a spring, so one row type bounced while the value row directly
        // beneath it eased. One focus response for the whole app.
        .animation(perf.motion(FusionFocus.liftAnimation), value: isFocused)
    }
}

/// Shared row backdrop for the redesigned settings: transparent when idle so
/// rows read as one grouped list, and an accent-tinted, ringed highlight when
/// focused. No per-row scale — the fill/ring alone carries focus.
struct SettingsRowBackground: View {
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
            .fill(isFocused ? CuePalette.focusBackground : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? CuePalette.focusRing : .clear, lineWidth: 3)
            )
    }
}

/// Every cache by kind with its size and allowance, and one clear for all
/// of it (`CacheStorage`): everything here loads again as needed.
struct CachePage: View {
    /// The total, back to Storage's row.
    let measured: (Int64) -> Void
    @State private var parts: [CacheStorage.Part] = []
    @State private var done = false
    @State private var clearing = false

    var body: some View {
        SettingsPage(title: "Cache",
                     subtitle: "Cue keeps pictures and title details on this Apple TV so pages open at once. "
                        + "Clearing them is safe: they load again as needed.") {
            SettingsSection {
                SettingsButtonRow(title: "Clear Cache",
                                  description: "Removes everything below. Your account, profiles, progress, "
                                    + "library and settings stay.",
                                  value: clearing ? "Clearing…" : (done ? Self.size(total) : nil)) {
                    clear()
                }
            }
            SettingsSection(title: "Cache") {
                SettingsInfoRows {
                    ForEach(parts) { part in
                        SettingsInfoRow(title: part.name, value: Self.value(part))
                    }
                }
            }
        }
        .task { await measure() }
    }

    private var total: Int64 { parts.reduce(0) { $0 + $1.bytes } }

    private func measure() async {
        parts = await CacheStorage.measure()
        done = true
        measured(total)
    }

    private func clear() {
        guard !clearing else { return }
        clearing = true
        Task {
            await CacheStorage.clear()
            await measure()
            clearing = false
        }
    }

    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private static func value(_ part: CacheStorage.Part) -> String {
        guard let limit = part.limit else { return size(part.bytes) }
        let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
        return part.bytes == 0 ? "Empty, up to \(limitText)" : "\(size(part.bytes)) of \(limitText)"
    }
}

// MARK: - Settings 2 (UIKit, 2026-11-23)

/// What Settings 2's pages read and change, and what the SwiftUI pages it
/// still opens (`SettingsNav`) need around them.
@MainActor
struct SettingsEnv {
    let account: NuvioAccountManager
    let watched: WatchedStore
    let progress: ProgressStore
    let library: LibraryStore
    let addons: AddonManager
    let profiles: ProfileStore
    let collections: CollectionsStore
    let home: HomeCatalogSettingsStore
    let tmdb: TMDBSettingsStore
    let mdblist: MDBListSettingsStore
    let player: PlayerSettingsStore
    let search: SearchViewModel
    var openTitle: ((MetaItem) -> Void)?

    func wrap(_ view: some View) -> AnyView {
        AnyView(view
            .environmentObject(account).environmentObject(watched).environmentObject(progress)
            .environmentObject(library).environmentObject(addons).environmentObject(profiles)
            .environmentObject(collections).environmentObject(home).environmentObject(tmdb)
            .environmentObject(mdblist).environmentObject(player).environmentObject(search)
            .environment(\.settingsOpenTitle, openTitle))
    }
}

/// SETTINGS 2: two columns of flat cards under the breadcrumbs — the
/// categories on the left (three groups), the focused one's settings on
/// the right; Right goes in, Left and Back come out. UIKit (2026-11-23:
/// the SwiftUI one dropped frames opening categories and needed its own
/// scroll), the pages its rows open too: over the category's, in the
/// column (Back takes them off).
struct CardSettingsRoot: UIViewControllerRepresentable {
    let onBack: () -> Void
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var home: HomeCatalogSettingsStore
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var player: PlayerSettingsStore
    @EnvironmentObject private var search: SearchViewModel
    @Environment(\.settingsOpenTitle) private var openTitle

    private var env: SettingsEnv {
        SettingsEnv(account: account, watched: watched, progress: progress, library: library, addons: addons,
                    profiles: profiles, collections: collections, home: home, tmdb: tmdb, mdblist: mdblist,
                    player: player, search: search, openTitle: openTitle)
    }

    func makeUIViewController(context: Context) -> CardSettingsController {
        let controller = CardSettingsController(env: env, onBack: onBack)
        TopBar.shared.entries[AppTab.settings.rawValue] = { [weak controller] in controller?.barEntry }
        return controller
    }

    func updateUIViewController(_ controller: CardSettingsController, context: Context) {
        controller.env = env
        controller.onBack = onBack
    }
}

/// What the gate shows in the settings' controller: a held profile's page,
/// or a new profile's.
enum GateMode {
    case edit(Int)
    case create(done: (UserProfile) -> Void)
}

/// A page over the "Who's watching?" gate: the settings' controller with
/// only a profile's page, centred (no categories, no Switch row: picking
/// switches); Back, or the profile deleted: out.
struct ProfileGateEditor: UIViewControllerRepresentable {
    let mode: GateMode
    let onBack: () -> Void
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var home: HomeCatalogSettingsStore
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var player: PlayerSettingsStore
    /// Not in the gate's environment, and the profile page never reads it.
    @StateObject private var search = SearchViewModel()

    private var env: SettingsEnv {
        SettingsEnv(account: account, watched: watched, progress: progress, library: library, addons: addons,
                    profiles: profiles, collections: collections, home: home, tmdb: tmdb, mdblist: mdblist,
                    player: player, search: search, openTitle: nil)
    }

    func makeUIViewController(context: Context) -> CardSettingsController {
        CardSettingsController(env: env, onBack: onBack, gateMode: mode)
    }

    func updateUIViewController(_ controller: CardSettingsController, context: Context) {
        controller.env = env
        controller.onBack = onBack
    }
}

final class CardSettingsController: UIViewController {
    var env: SettingsEnv
    var onBack: () -> Void
    /// The gate's page (a profile's, or a new one's) alone, centred.
    let gateMode: GateMode?
    private var editPage: UISettingsPage?
    let keyboard = UISettingsKeyboard()

    static let leftWidth: CGFloat = 480
    static let columnGap: CGFloat = 40
    static var rightWidth: CGFloat { 1920 - 2 * FixedFocusMetrics.inset - leftWidth - columnGap }
    static let crumbsSize: CGFloat = 29
    static let crumbsGap: CGFloat = 40
    private static let groups: [(String, [SettingsCategory])] = [
        ("Accounts", SettingsCategory.accounts),
        ("Watching", [.homeContent, .playback, .appearance]),
        ("This Apple TV", [.storage, .developer, .about]),
    ]

    private let crumbs = UILabel()
    private let menu = UIStackView()
    private var menuRows: [SettingsCategory: UISettingsLinkRow] = [:]
    private var pages: [SettingsCategory: UISettingsPage] = [:]
    /// The pages opened over the category's, the last on top.
    private var stack: [UISettingsPage] = []
    private let leftGuide = UIFocusGuide()
    private let rightGuide = UIFocusGuide()

    private(set) var shown = SettingsCategory.account
    /// Focus is in the settings (not on a category).
    private var inSettings = false
    /// Where a focus update asked for should land.
    private weak var wanted: UIView?
    /// The rows that opened each page in the column (Back lands on them).
    private var cameFrom: [UIView?] = []

    init(env: SettingsEnv, onBack: @escaping () -> Void, gateMode: GateMode? = nil) {
        self.env = env
        self.onBack = onBack
        self.gateMode = gateMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var columnsTop: CGFloat {
        StagePictureView.homeCard.minY + ceil(UIFont.systemFont(ofSize: Self.crumbsSize, weight: .semibold).lineHeight)
            + Self.crumbsGap
    }

    private var creating: Bool { if case .create = gateMode { return true } else { return false } }

    private var rightColumn: CGRect {
        if creating {
            // Under the wizard's heading, above its buttons, from the rows'
            // edge (a summary's card: Settings' column width).
            let top = Self.wizardTop
            let width = wizardLayout == .summary ? Self.summaryWidth : 1920 - 2 * FixedFocusMetrics.inset
            return CGRect(x: (1920 - width) / 2, y: top, width: width,
                          height: Self.wizardButtonsTop - 24 - top)
        }
        return CGRect(x: gateMode == nil ? FixedFocusMetrics.inset + Self.leftWidth + Self.columnGap : (1920 - Self.rightWidth) / 2,
               y: columnsTop,
               width: Self.rightWidth, height: 1080 - columnsTop)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        keyboard.attach(to: view)

        // As Upcoming's month (Home's row names): their font, line and drop;
        // at Settings' own text edge, over the categories' labels.
        crumbs.font = FixedFocusRowCell.titleFont
        crumbs.frame = CGRect(x: FixedFocusMetrics.inset + UISettings.textInset,
                              y: StagePictureView.homeCard.minY + FixedFocusMetrics.titleDrop,
                              width: 1920 - 2 * FixedFocusMetrics.inset, height: FixedFocusMetrics.titleLine)
        view.addSubview(crumbs)

        if let gateMode {
            let page: UISettingsPage = switch gateMode {
            case .edit(let id): UIProfileEditPage(host: self, profileID: id, fromGate: true)
            case .create(let done): UINewProfilePage(host: self, fromGate: true, onCreated: done)
            }
            page.fadesAtFoot = creating
            page.place(column: rightColumn)
            view.insertSubview(page, belowSubview: crumbs)
            page.visible = true
            editPage = page
            if creating { buildChrome() }
            page.appeared()
            NotificationCenter.default.addObserver(forName: .gateEditorBack, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.back() }
            }
            crumbs.frame.origin.x = rightColumn.minX + UISettings.textInset
            if !creating { updateCrumbs() }
            return
        }

        // The categories: three groups, each its card under its label, 24
        // apart, the rows compact: all of it in view.
        menu.axis = .vertical
        menu.spacing = 24
        for (label, categories) in Self.groups {
            let section = UISettingsSectionView(compact: true)
            section.set(UISettingsSection(label: label, rows: categories.map { category in
                .link(.init(id: category.rawValue, title: category.title, chevron: false) {})
            }))
            for (category, row) in zip(categories, section.card.rows) {
                guard let row = row as? UISettingsLinkRow else { continue }
                row.reachable = { [weak self] in
                    guard let self else { return true }
                    return !self.inSettings || self.shown == category
                }
                menuRows[category] = row
            }
            menu.addArrangedSubview(section)
        }
        menu.frame = CGRect(x: FixedFocusMetrics.inset, y: columnsTop, width: Self.leftWidth, height: 0)
        let menuSize = menu.systemLayoutSizeFitting(CGSize(width: Self.leftWidth, height: 0),
                                                     withHorizontalFittingPriority: .required,
                                                     verticalFittingPriority: .fittingSizeLevel)
        menu.frame.size.height = menuSize.height
        view.addSubview(menu)

        // Left from the settings: the category shown; Right from the
        // categories: into its settings.
        for guide in [leftGuide, rightGuide] { view.addLayoutGuide(guide) }
        NSLayoutConstraint.activate([
            leftGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FixedFocusMetrics.inset),
            leftGuide.widthAnchor.constraint(equalToConstant: Self.leftWidth),
            leftGuide.topAnchor.constraint(equalTo: view.topAnchor, constant: columnsTop),
            leftGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rightGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: rightColumn.minX),
            rightGuide.widthAnchor.constraint(equalToConstant: Self.rightWidth),
            rightGuide.topAnchor.constraint(equalTo: view.topAnchor, constant: columnsTop),
            rightGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        show(.account)
        refreshFocusState(focused: nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        (stack.last ?? base)?.leave()
        TopBarLock.shared.locked = false
    }

    /// Down from the top bar: the category shown.
    /// Down from the top bar: back where Up left from (a row in the right
    /// column), while it's still there; else the shown category.
    var barEntry: UIView? {
        if let leftFrom, leftFrom.window != nil, leftFrom.canBecomeFocused,
           !sequence(first: leftFrom, next: { $0.superview }).contains(where: \.isHidden) { return leftFrom }
        return menuRows[shown]
    }
    private weak var leftFrom: UIView?

    /// The page under the opened ones: the category's, or the gate's profile.
    private var base: UISettingsPage? { editPage ?? pages[shown] }

    // MARK: Pages

    private func page(_ category: SettingsCategory) -> UISettingsPage {
        if let page = pages[category] { return page }
        let page: UISettingsPage = switch category {
        case .account: NuvioSettingsPage(host: self)
        case .tmdb: TMDBSettingsPage(host: self)
        case .mdblist: MDBListSettingsPage(host: self)
        case .appearance: AppearanceSettingsPage(host: self)
        case .homeContent: HomeSettingsPage(host: self)
        case .playback: PlaybackSettingsPage(host: self)
        case .storage: StorageSettingsPage(host: self)
        case .about: AboutSettingsPage(host: self)
        case .developer: DeveloperSettingsPage(host: self)
        }
        page.place(column: rightColumn)
        page.isHidden = true
        view.insertSubview(page, belowSubview: crumbs)
        pages[category] = page
        return page
    }

    /// A category's settings in the column: at its top, as it opens; the
    /// pages opened from the last one gone.
    private func show(_ category: SettingsCategory) {
        if category != shown || pages[category] == nil {
            if let old = pages[shown], category != shown {
                old.leave()
                old.isHidden = true
                old.visible = false
            }
            shown = category
        }
        for page in stack.reversed() {
            page.leave()
            page.removeFromSuperview()
        }
        stack = []
        cameFrom = []
        let page = page(category)
        page.reset()
        page.isHidden = false
        page.visible = true
        page.appeared()
        updateCrumbs()
    }

    /// A page a row opened, over the one it's on (that one goes; its
    /// changes are sent as it does), fading in; focus on its first row.
    func open(_ page: UISettingsPage) {
        let below = stack.last ?? base
        cameFrom.append(UISettings.focusedView(in: view))
        below?.leave()
        below?.isHidden = true
        below?.visible = false
        page.place(column: rightColumn)
        page.alpha = 0
        view.insertSubview(page, belowSubview: crumbs)
        stack.append(page)
        page.visible = true
        page.appeared()
        UIView.animate(withDuration: Motion.fadeDuration) { page.alpha = 1 }
        focus(page)
        updateCrumbs()
    }

    /// Back a page: the one under it again, focus on the row that opened it.
    func close() {
        guard let page = stack.popLast() else { return }
        page.leave()
        page.visible = false
        page.removeFromSuperview()
        let below = stack.last ?? base
        below?.isHidden = false
        below?.visible = true
        below?.appeared()
        let back = cameFrom.popLast() ?? nil
        focus(back ?? below)
        updateCrumbs()
    }

    /// Off this page, wherever it is (a removed profile, add-on).
    func close(_ page: UISettingsPage) {
        guard stack.last === page else { return }
        close()
    }

    // MARK: The wizard's heading, preview and buttons

    /// A new profile's screens, centred (one question a screen; left-aligned
    /// was tried 2026-11-24: the right half sat empty, the preview lost in
    /// its corner): the step over the question, the profile so far small
    /// beside the step (large under the question looked bad), its line under
    /// it; the buttons bottom centre, the same spot on every step.
    enum WizardLayout { case plain, summary }
    static let headingSize: CGFloat = 57
    static var stepLineY: CGFloat { StagePictureView.homeCard.minY }
    static let stepLineHeight: CGFloat = 44
    static var wizardHeadingY: CGFloat { stepLineY + stepLineHeight + 12 }
    static var wizardTop: CGFloat { wizardHeadingY + 70 + 8 + 34 + 36 }
    static let summaryWidth: CGFloat = 1000
    static let wizardButtonsFoot: CGFloat = 1080 - 120
    static let wizardButtonHeight: CGFloat = 52
    static var wizardButtonsTop: CGFloat { wizardButtonsFoot - wizardButtonHeight }

    private let heading = UILabel()
    private let subheading = UILabel()
    private var wizardLayout = WizardLayout.plain
    private var stepLine: UISettingsHosted?
    private var stepKey = ""
    private var stepText = ""
    private var shownProfile: UserProfile?
    private let buttonStack = UIStackView()
    private var buttonViews: [String: UISettingsRoundButton] = [:]
    /// A strip the screen's width above the buttons: Down from the page to
    /// the buttons, Up from them back to the page.
    private let toButtons = UIFocusGuide()

    private func buildChrome() {
        heading.font = .systemFont(ofSize: Self.headingSize, weight: .semibold)
        heading.textColor = CueInk.ui(FixedFocusText.primary)
        heading.textAlignment = .center
        heading.frame = CGRect(x: 0, y: Self.wizardHeadingY, width: 1920, height: 70)
        subheading.font = .systemFont(ofSize: 24, weight: .regular)
        subheading.textColor = CueInk.ui(FixedFocusText.body)
        subheading.textAlignment = .center
        subheading.frame = CGRect(x: 0, y: heading.frame.maxY + 8, width: 1920, height: 34)
        for view in [heading, subheading] as [UIView] { self.view.addSubview(view) }
        crumbs.isHidden = true

        buttonStack.axis = .horizontal
        buttonStack.spacing = 24
        buttonStack.alignment = .center
        view.addSubview(buttonStack)
        view.addLayoutGuide(toButtons)
        NSLayoutConstraint.activate([
            toButtons.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toButtons.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toButtons.bottomAnchor.constraint(equalTo: view.topAnchor, constant: Self.wizardButtonsTop - 10),
            toButtons.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    func setChrome(_ title: String, _ subtitle: String?, step: Int, count: Int) {
        guard creating else { return }
        if heading.text != title || subheading.text != subtitle {
            UIView.transition(with: view, duration: Motion.fadeDuration, options: .transitionCrossDissolve) {
                self.heading.text = title
                self.subheading.text = subtitle
            }
        }
        stepText = "Step \(step + 1) of \(count)"
        drawStepLine()
    }

    /// The step, with the profile so far beside it once it has an avatar
    /// (not on the avatar's own step: it's large there).
    private func drawStepLine() {
        let small = shownProfile
        let key = stepText + "|" + (small.map { "\($0.avatarColorHex)|\($0.avatarID ?? "")|\($0.name)" } ?? "")
        guard key != stepKey else { return }
        stepKey = key
        let text = stepText
        let line = env.wrap(HStack(spacing: 14) {
            if let small {
                ProfileAvatarView(profile: small, size: Self.stepLineHeight)
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 1.5) }
                Text(small.name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(CueInk.color(FixedFocusText.primary))
                    .lineLimit(1)
                Text("·").font(.system(size: 24, weight: .medium)).foregroundStyle(CueInk.color(FixedFocusText.tertiary))
            }
            Text(text)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(CueInk.color(FixedFocusText.secondary))
        }.frame(width: 1920, height: Self.stepLineHeight))
        if let stepLine { stepLine.set(line) } else {
            let made = UISettingsHosted(line)
            made.frame = CGRect(x: 0, y: Self.stepLineY, width: 1920, height: Self.stepLineHeight)
            view.addSubview(made)
            stepLine = made
        }
    }

    /// The profile so far (nil: none yet, the name's step), small beside
    /// the step; on the avatar's step it follows focus.
    func setPreview(_ profile: UserProfile?) {
        guard creating else { return }
        shownProfile = profile
        drawStepLine()
    }

    /// The name's step while the keyboard is up: nothing of it shows under
    /// the keyboard coming in (it flashed before).
    func setChromeHidden(_ hidden: Bool) {
        guard creating else { return }
        let alpha: CGFloat = hidden ? 0 : 1
        let views = [heading, subheading, stepLine, buttonStack].compactMap { $0 as UIView? }
        guard views.contains(where: { $0.alpha != alpha }) else { return }
        if hidden {
            views.forEach { $0.alpha = 0 }
        } else {
            UIView.animate(withDuration: Motion.fadeDuration) { views.forEach { $0.alpha = 1 } }
        }
    }

    /// The step's buttons, bottom centre (none: Select on the page goes on).
    func setButtons(_ actions: [SettingsAction]) {
        guard creating else { return }
        var kept: [UISettingsRoundButton] = []
        for action in actions {
            let button = buttonViews[action.id] ?? UISettingsRoundButton()
            buttonViews[action.id] = button
            button.set(icon: action.icon, danger: action.danger, nudge: 0)
            button.set(words: action.title)
            button.accessibilityLabel = action.title
            button.onSelect = { action.action() }
            kept.append(button)
        }
        for (key, button) in buttonViews where !kept.contains(where: { $0 === button }) {
            button.removeFromSuperview()
            buttonViews[key] = nil
        }
        for (index, button) in kept.enumerated() where buttonStack.arrangedSubviews.firstIndex(of: button) != index {
            buttonStack.insertArrangedSubview(button, at: index)
        }
        let size = buttonStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        buttonStack.frame = CGRect(x: (1920 - size.width) / 2, y: Self.wizardButtonsTop,
                                   width: size.width, height: Self.wizardButtonHeight)
        aimButtonsGuide(focused: UISettings.focusedView(in: view))
    }

    /// From the page the strip leads to the buttons; from them, back.
    private func aimButtonsGuide(focused: UIView?) {
        let inButtons = focused?.isDescendant(of: buttonStack) ?? false
        if inButtons {
            toButtons.preferredFocusEnvironments = editPage.map { [$0] } ?? []
            toButtons.isEnabled = editPage?.firstFocusable != nil
        } else {
            toButtons.preferredFocusEnvironments = buttonStack.arrangedSubviews.first.map { [$0] } ?? []
            toButtons.isEnabled = !buttonStack.arrangedSubviews.isEmpty
        }
    }

    /// Where the page sits: under the question, under the large preview
    /// (the avatar's step), or a card of Settings' rows' width (the summary).
    func setWizardLayout(_ layout: WizardLayout) {
        guard creating, layout != wizardLayout, let editPage else { return }
        wizardLayout = layout
        editPage.place(column: rightColumn)
    }

    /// Focus to the page's first row (a step changed); a step with nothing
    /// to press on the page, or `buttons`: to its first button.
    func refocusPage(buttons: Bool = false) {
        if creating, buttons || editPage?.firstFocusable == nil, let first = buttonStack.arrangedSubviews.first {
            focus(first)
        } else {
            focus(editPage)
        }
    }

    // MARK: Breadcrumbs

    /// Where you are, over both columns at the rows' words: the category,
    /// the pages opened from it — the last at primary. (The group was
    /// dropped 2026-11-23: its label is beside the category already.)
    private func updateCrumbs() {
        guard !creating else { return }
        let names = [editPage?.title ?? shown.title] + stack.compactMap(\.title)
        let text = NSMutableAttributedString()
        for (index, name) in names.enumerated() {
            let last = index == names.count - 1
            text.append(NSAttributedString(string: name + (last ? "" : "  ›  "), attributes: [
                .foregroundColor: CueInk.ui(last ? FixedFocusText.primary : FixedFocusText.tertiary),
            ]))
        }
        crumbs.attributedText = text
    }

    // MARK: Focus

    private func focus(_ target: UIView?) {
        wanted = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let wanted, wanted.window != nil { return [wanted] }
        if creating, editPage?.firstFocusable == nil, let first = buttonStack.arrangedSubviews.first { return [first] }
        if let editPage { return [stack.last ?? editPage] }
        return menuRows[shown].map { [$0] } ?? []
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Focus leaving Settings (Up to the bar): where from, unless the categories.
        if let from = context.previouslyFocusedView, from.isDescendant(of: view),
           !(context.nextFocusedView?.isDescendant(of: view) ?? false) {
            leftFrom = from.isDescendant(of: menu) ? nil : from
        }
        wanted = nil
        if creating { aimButtonsGuide(focused: context.nextFocusedView) }
        refreshFocusState(focused: context.nextFocusedView)
    }

    private func refreshFocusState(focused next: UIView?) {
        if editPage != nil { return }
        if let next, let category = menuRows.first(where: { $0.value === next })?.key {
            inSettings = false
            if category != shown { show(category) }
        } else if let next, next.isDescendant(of: view), !next.isDescendant(of: menu) {
            inSettings = true
        }
        for (category, row) in menuRows { row.selected = inSettings && category == shown }
        leftGuide.isEnabled = inSettings
        leftGuide.preferredFocusEnvironments = menuRows[shown].map { [$0] } ?? []
        rightGuide.isEnabled = !inSettings
        rightGuide.preferredFocusEnvironments = [stack.last ?? pages[shown]].compactMap { $0 }
    }

    // MARK: Back

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesBegan(presses, with: event) }
        back()
    }

    private func back() {
        if !stack.isEmpty { close() }
        else if let editPage {
            if editPage.handleBack() { return }
            editPage.leave()
            onBack()
        }
        else if inSettings { focus(menuRows[shown]) }
        else { onBack() }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesEnded(presses, with: event) }
    }

    // MARK: For the pages

    /// A screen over everything (sign-in, a new profile, a PIN).
    func present(_ content: some View) {
        let host = UIHostingController(rootView: env.wrap(content))
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    func dismissPresented() { presentedViewController?.dismiss(animated: true) }
}

/// A category's page: its sections built from what it reads, again on
/// every change (the rows keep their views), only while it's shown.
@MainActor
class UISettingsPage: UISettingsPageView {
    unowned let host: CardSettingsController
    var env: SettingsEnv { host.env }
    /// A page a row opened: its name, for the breadcrumbs.
    var title: String? { nil }
    private var bag = Set<AnyCancellable>()
    private var queued = false
    private var dirty = true
    var visible = false { didSet { if visible, dirty { reload() } } }

    init(host: CardSettingsController) {
        self.host = host
        super.init()
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Back on the page itself: true when it took a step back instead.
    func handleBack() -> Bool { false }

    /// What the page watches.
    func setUp() {}
    func sections() -> [UISettingsSection] { [] }
    func appeared() {}
    func disappeared() {}

    /// What waits for the page to be left (Remove, Delete, Sign Out: no
    /// confirmation, Undo in place until then), by key.
    private var held: [String: () -> Void] = [:]
    func hold(_ key: String, _ action: @escaping () -> Void) { held[key] = action; changed() }
    func undo(_ key: String) { held[key] = nil; changed() }
    func isHeld(_ key: String) -> Bool { held[key] != nil }

    /// Left (Back, another category, a page opened over it, the tab): what
    /// it held is done.
    func leave() {
        disappeared()
        let actions = held.values
        held = [:]
        actions.forEach { $0() }
    }

    /// Undo for what a page holds: one key both ways, so focus stays on it.
    static func undoAction(_ key: String, spelled: Bool = false, title: String = "Undo",
                           _ action: @escaping () -> Void) -> SettingsAction {
        SettingsAction(title: title, icon: "arrow.uturn.backward", key: key, spelled: spelled, action: action)
    }

    func watch<O: ObservableObject>(_ object: O) {
        object.objectWillChange.sink { [weak self] _ in self?.changed() }.store(in: &bag)
    }

    func watch<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher.sink { [weak self] _ in self?.changed() }.store(in: &bag)
    }

    /// Built again after this runloop (`objectWillChange` comes before the change).
    func changed() {
        guard visible else { dirty = true; return }
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.reload()
        }
    }

    func reload() {
        dirty = false
        set(sections())
    }

    /// The defaults a page's settings live in (`@AppStorage`'s).
    func watchDefaults() { watch(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) }

    // MARK: A service's key

    /// The key's row's state: checking a new one, a failed one, whether
    /// the saved one works (nil until known).
    final class KeyState {
        var checking = false
        var failed = false
        var works: Bool?
        var checked: String?
    }

    /// "API Key" over the key (masked) and whether it works; Type, Send
    /// from Phone, Remove (Undo until the page is left). A new key is checked before it's
    /// saved.
    func keyRow(_ service: ServiceKey, key: String, state: KeyState,
                setKey: @escaping (String) -> Void) -> UISettingsRow {
        if state.checked != key {
            state.checked = key
            state.works = nil
            if !key.isEmpty {
                Task { [weak self] in
                    let works = await service.check(key)
                    guard state.checked == key else { return }
                    state.works = works
                    self?.changed()
                }
            }
        }
        let detail: String
        if state.checking { detail = "Checking the key…" }
        else if state.failed { detail = "That key didn't work. Check you copied all of it." }
        else if key.isEmpty { detail = "Not added" }
        else { detail = ServiceKey.masked(key) + (state.works == false ? " · Not working" : state.works == true ? " · Working" : "") }
        let check: (String) -> Void = { [weak self] text in
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }
            state.checking = true
            state.failed = false
            self?.changed()
            Task { [weak self] in
                let valid = await service.validate(candidate)
                state.checking = false
                if valid { setKey(candidate) } else { state.failed = true }
                self?.changed()
            }
        }
        var actions = [
            SettingsAction(title: key.isEmpty ? "Type Key" : "Type a New Key", icon: "keyboard", key: "type") { [weak self] in
                self?.host.keyboard.ask(text: "", placeholder: "\(service.name) API key", commit: check)
            },
            SettingsAction(title: "Send from Phone", icon: "qrcode", key: "phone") { [weak self] in
                self?.host.present(KeyHandoffPage(service: service, save: setKey) { self?.host.dismissPresented() })
            },
        ]
        let held = "key." + service.name
        if isHeld(held) {
            return .actions(.init(id: "key.\(service.name)", title: "API Key", detail: "Removed", dimmed: true,
                                  actions: [Self.undoAction("remove") { [weak self] in self?.undo(held) }]))
        }
        if !key.isEmpty {
            actions.append(SettingsAction(title: "Remove Key", icon: "trash", danger: true, key: "remove") { [weak self] in
                self?.hold(held) { setKey("") }
            })
        }
        return .actions(.init(id: "key.\(service.name)", title: "API Key", detail: detail, actions: actions))
    }
}

// MARK: The categories

private final class NuvioSettingsPage: UISettingsPage {
    override func setUp() {
        watch(env.account)
        watch(env.addons)
        watch(env.progress)
        watch(env.library)
        watch(env.watched)
        watch(env.profiles)
        if let sync = NuvioSyncManager.shared { watch(sync) }
    }

    override func sections() -> [UISettingsSection] {
        guard case .signedIn(_, let email) = env.account.authState else {
            // Signed out: the two ways in, on the row.
            return [UISettingsSection(rows: [.actions(.init(
                id: "n.signin", title: "Account", detail: "Not signed in",
                actions: [
                    SettingsAction(title: "Sign In with Phone", icon: "qrcode") { [weak self] in self?.signIn(emailOnly: false) },
                    SettingsAction(title: "Sign In with Email", icon: "envelope") { [weak self] in self?.signIn(emailOnly: true) },
                ]))])]
        }
        let profiles = env.profiles
        var profileRows: [UISettingsRow] = profiles.profiles.map { profile in
            let active = profile.id == profiles.activeProfileID
            return .actions(.init(
                id: "n.profile.\(profile.id)",
                leading: .init(key: String(describing: profile)) { AnyView(ProfileAvatarView(profile: profile, size: 56)) },
                title: profile.name,
                detail: Self.profileDetail(profiles.notes(for: profile), pin: profile.pinEnabled),
                actions: (active ? [] : [
                    SettingsAction(title: "Switch to \(profile.name)", icon: "arrow.right.circle", key: "switch") { [weak self] in
                        self?.switchTo(profile)
                    },
                ]) + [
                    SettingsAction(title: "Edit", icon: "pencil", key: "edit") { [weak self] in
                        guard let self else { return }
                        self.host.open(UIProfileEditPage(host: self.host, profileID: profile.id))
                    },
                ]))
        }
        // A row for them all on top: Add Profile (a plus) and how many more
        // fit; at the most, the count and how to make room.
        let room = ProfileStore.maxProfiles - profiles.profiles.count
        profileRows.insert(.actions(.init(
            id: "n.profiles",
            title: profiles.canAddProfile ? "Add Profile" : "\(profiles.profiles.count) of \(ProfileStore.maxProfiles) Profiles",
            detail: !profiles.canAddProfile ? "Delete one to add another."
                : room == 1 ? "1 more can be added." : "\(room) more can be added.",
            actions: profiles.canAddProfile ? [
                SettingsAction(title: "Add Profile", icon: "plus", key: "add") { [weak self] in self?.addProfile() },
            ] : [])), at: 0)
        return [
            // The account (its email, Sync Now and Sign Out, held), then
            // what it syncs, in one card: they belong together.
            UISettingsSection(rows: [isHeld("signout")
                ? .actions(.init(id: "n.account", title: "Account", detail: "Signed out when you leave", dimmed: true,
                                 actions: [Self.undoAction("signout") { [weak self] in self?.undo("signout") }]))
                : .actions(.init(
                id: "n.account", title: "Account",
                detail: (email.isEmpty ? "Nuvio account" : email) + " · " + Self.syncState,
                actions: [
                    SettingsAction(title: "Sync Now", icon: "arrow.triangle.2.circlepath", key: "sync") {
                        Task { await NuvioSyncManager.shared?.syncNow() }
                    },
                    SettingsAction(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right", danger: true, key: "signout", nudge: 2) { [weak self] in
                        guard let self else { return }
                        let account = self.env.account
                        self.hold("signout") { account.signOut() }
                    },
                ])),
                syncRow("n.addons", "Add-ons", env.addons.addons.count) { UIAddonsPage(host: $0) },
                syncRow("n.progress", "Watch Progress", env.progress.items.count) { UIWatchProgressPage(host: $0) },
                syncRow("n.library", "Library", env.library.items.count) { UILibraryPage(host: $0) },
                syncRow("n.watched", "Watched", env.watched.items.count) { UIWatchedPage(host: $0) },
            ]),
            // Every profile: Switch (not the active one) and Edit on its row.
            UISettingsSection(label: "Profiles", rows: profileRows),
        ]
    }

    private func syncRow(_ id: String, _ title: String, _ count: Int,
                         page: @escaping (CardSettingsController) -> UISettingsPage) -> UISettingsRow {
        .link(.init(id: id, title: title, value: count.formatted()) { [weak self] in
            guard let host = self?.host else { return }
            host.open(page(host))
        })
    }

    private func signIn(emailOnly: Bool) {
        host.present(NuvioSignInView(account: env.account, onSignedIn: { [weak self] in self?.host.dismissPresented() },
                                     emailOnly: emailOnly, onClose: { [weak self] in self?.host.dismissPresented() })
            .onExitCommand { [weak self] in self?.host.dismissPresented() })
    }

    private func addProfile() {
        host.present(ProfileGateEditor(mode: .create { [weak self] _ in self?.host.dismissPresented() }) { [weak self] in
            self?.host.dismissPresented()
        }
        .ignoresSafeArea()
        .background(ATVBackground())
        .onExitCommand { NotificationCenter.default.post(name: .gateEditorBack, object: nil) })
    }

    private func switchTo(_ profile: UserProfile) {
        guard profile.pinEnabled else { env.profiles.setActive(profile.id); return }
        host.present(ProfilePinCheck(profile: profile) { [weak self] in
            self?.host.dismissPresented()
            self?.env.profiles.setActive(profile.id)
        } onCancel: { [weak self] in self?.host.dismissPresented() })
    }

    /// "Primary, Active · PIN"; neither: "Profile".
    static func profileDetail(_ notes: String, pin: Bool) -> String {
        let parts = [notes.isEmpty ? nil : notes, pin ? "PIN" : nil].compactMap { $0 }
        return parts.isEmpty ? "Profile" : parts.joined(separator: " · ")
    }

    private static var syncState: String {
        guard let sync = NuvioSyncManager.shared else { return "—" }
        if sync.isSyncing { return "Syncing…" }
        if sync.lastSyncError != nil { return "Sync failed" }
        guard let last = sync.lastSyncedAt else { return "Not synced yet" }
        return "Synced " + DateFormatter.settingsWhen.string(from: last)
    }
}

private final class TMDBSettingsPage: UISettingsPage {
    private let key = KeyState()

    override func setUp() { watch(env.tmdb) }

    override func sections() -> [UISettingsSection] {
        let tmdb = env.tmdb
        let apiKey = tmdb.settings.trimmedAPIKey
        let options = TMDBLanguages.options.map { SettingsOption(id: $0, label: TMDBLanguages.displayName($0)) }
        let description = "Titles, taglines and descriptions in this language where TMDB has it."
        let selection = tmdb.settings.language
        // One card: the key (its how-to while there's none), then Language.
        return [
            UISettingsSection(rows: [keyRow(.tmdb, key: apiKey, state: key) { tmdb.setAPIKey($0) }]
                              + (apiKey.isEmpty ? [.note(ServiceKey.tmdb.howTo)] : []) + [
                .link(.init(id: "t.language", title: "Language", description: description,
                            value: options.first { $0.id == selection }?.label) { [weak self] in
                    guard let host = self?.host else { return }
                    host.open(UIOptionsPage(host: host, title: "Language", options: options,
                                            selection: selection) { tmdb.settings.language = $0 })
                }),
            ]),
        ]
    }
}

private final class MDBListSettingsPage: UISettingsPage {
    private let key = KeyState()
    /// The provider lifted to move.
    private var moving: MDBListProvider? { didSet { TopBarLock.shared.locked = moving != nil; changed() } }

    override func setUp() {
        watch(env.mdblist)
        watch(MDBListUsage.shared)
    }

    override func disappeared() { moving = nil }

    override func sections() -> [UISettingsSection] {
        let mdblist = env.mdblist
        let usage = MDBListUsage.shared
        let apiKey = mdblist.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // The key on its row; what MDBList last said of the account under it, only to read.
        var account: [UISettingsRow] = [keyRow(.mdblist, key: apiKey, state: key) { new in
            mdblist.settings.apiKey = new
            // Kept true for older Cue versions, which still read it.
            mdblist.settings.enabled = !new.isEmpty
        }]
        if apiKey.isEmpty {
            account.append(.note(ServiceKey.mdblist.howTo))
        } else {
            if let plan = usage.account, !plan.plan.isEmpty {
                account.append(.info(title: "Plan", value: plan.username.isEmpty ? plan.plan : "\(plan.username) · \(plan.plan)"))
            }
            if let snapshot = usage.snapshot {
                account.append(.info(title: "Requests Today", value: snapshot.requestsToday))
            }
        }
        // Ratings, one card: where they show on top, then the sources in
        // order (the first three on titles, the rest standing in; Move on
        // each) — only with a key (without one, IMDb's alone) and ratings on.
        let place: UISettingsRow = .choice(.init(
            id: "m.place", title: "Show Ratings", description: "Everywhere, on Details only, or nowhere.",
            options: RatingsPlace.allCases.reversed().map { SettingsOption(id: $0.rawValue, label: $0.label) },
            selection: mdblist.settings.place.rawValue) { mdblist.settings.place = RatingsPlace(rawValue: $0) ?? .everywhere })
        let providers = apiKey.isEmpty || mdblist.settings.place == .off ? [] : mdblist.settings.orderedProviders
        return [
            UISettingsSection(rows: account),
            UISettingsSection(label: "Ratings", rows: [place] + providers.enumerated().map { index, provider in
                .actions(.init(
                    id: "m.p.\(provider.id)",
                    leading: .init(key: provider.id) { AnyView(RatingMark(provider: provider).frame(height: 24)) },
                    title: provider.fullName,
                    detail: index < FixedFocusBillboardText.ratingsShown ? "Shown on titles" : "Stands in when one is missing",
                    actions: [SettingsAction(title: "Move", icon: "arrow.up.arrow.down", move: true) { [weak self] in
                        self?.moving = provider
                    }],
                    moving: moving == provider, anyMoving: moving != nil,
                    onMove: { mdblist.settings.move(provider, by: $0) },
                    onDrop: { [weak self] in self?.moving = nil }))
            }),
        ]
    }
}

private final class AppearanceSettingsPage: UISettingsPage {
    /// Saved ones removed here, done when the page is left (undo in place).
    private var pending: Set<String> = [] { didSet { changed() } }

    override func disappeared() {
        for id in pending { BackgroundStore.shared.unsave(id) }
        pending = []
    }

    override func setUp() {
        watch(BackgroundStore.shared)
        watchDefaults()
    }

    private static let defaults = UserDefaults.standard
    /// A saved one's page: its bands large.

    override func sections() -> [UISettingsSection] {
        let background = BackgroundStore.shared
        let outline = FixedFocusRing.outlines
        let atLaunch = Self.defaults.string(forKey: BackgroundPicks.AtLaunch.key) ?? BackgroundPicks.AtLaunch.home.rawValue
        // Card Outlines alone first (the one not about the background),
        // then the background: the one up large, Change at Launch, the saved ones.
        return [
            UISettingsSection(rows: [
                .choice(.init(
                    id: "a.outlines", title: "Card Outlines", description: "How cards are framed, at rest and in focus.",
                    options: [
                        SettingsOption(id: FixedFocusRing.Outlines.off.rawValue, label: "Off",
                                       detail: "No edges: the pictures alone."),
                        SettingsOption(id: FixedFocusRing.Outlines.low.rawValue, label: "Edges Only",
                                       detail: "A thin edge on every card, none brighter."),
                        SettingsOption(id: FixedFocusRing.Outlines.high.rawValue, label: "Edges and Focus",
                                       detail: "A thin edge on every card, a bright one in focus."),
                    ],
                    selection: outline.rawValue) { [weak self] in
                        FixedFocusRing.outlines = FixedFocusRing.Outlines(rawValue: $0) ?? .high
                        self?.changed()
                    }),
            ]),
            UISettingsSection(label: "Background", rows: [
                current(background),
                .choice(.init(
                    id: "a.launch", title: "Change at Launch", description: "What each launch brings.",
                    options: BackgroundPicks.AtLaunch.allCases.reversed()
                        .filter { $0 != .saved || !background.saved.isEmpty }
                        .map { SettingsOption(id: $0.rawValue, label: $0.label, detail: Self.launchDetail($0)) },
                    selection: atLaunch) { [weak self] in
                        Self.defaults.set($0, forKey: BackgroundPicks.AtLaunch.key)
                        self?.changed()
                    }),
            ]),
        ] + savedSection(background)
    }

    /// The saved ones in a card of their own: a row on top (the count,
    /// Remove All), then each.
    private func savedSection(_ background: BackgroundStore) -> [UISettingsSection] {
        let saved = background.saved
        guard !saved.isEmpty else { return [] }
        let left = saved.count - pending.count
        let header: UISettingsRow = .actions(.init(
            id: "a.savedHeader", title: left == 1 ? "1 Saved" : "\(left) Saved",
            detail: "Up to \(BackgroundPicks.savedLimit). Change at Launch can pick from them.",
            actions: [left == 0
                ? Self.undoAction("all", spelled: true, title: "Undo All") { [weak self] in self?.pending = [] }
                : SettingsAction(title: "Remove All", icon: "trash", danger: true, key: "all", spelled: true) { [weak self] in
                    self?.pending = Set(saved.map(\.id))
                }]))
        return [UISettingsSection(label: "Saved", rows: [header] + saved.map { self.saved($0, background) })]
    }

    /// The one up: its colours, how it came; Shuffle and Save on the row.
    private func current(_ background: BackgroundStore) -> UISettingsRow {
        let shown = background.shown
        let isSaved = shown.map { background.isSaved($0.id) && !pending.contains($0.id) } ?? false
        return .actions(.init(
            id: "a.background",
            leading: .init(key: shown?.id ?? "grey", size: BackgroundColours.size) { AnyView(BackgroundColours(entry: shown)) },
            title: shown?.name ?? "Grey",
            detail: Self.reason(background),
            actions: [
                SettingsAction(title: "Shuffle", icon: "shuffle", key: "shuffle") { background.another() },
            ] + (shown == nil ? [] : [
                SettingsAction(title: isSaved ? "Saved" : "Save", icon: isSaved ? "bookmark.fill" : "bookmark", key: "save") { [weak self] in
                    guard let self else { return }
                    if let id = shown?.id, self.pending.contains(id) { self.pending.remove(id) } else { background.toggleSaved() }
                },
            ])))
    }

    /// A saved one: Use (a checkmark on the one up), Remove (undo in place).
    private func saved(_ entry: BackgroundPicks.Entry, _ background: BackgroundStore) -> UISettingsRow {
        let gone = pending.contains(entry.id)
        let up = background.shown?.id == entry.id
        return .actions(.init(
            id: "a.saved.\(entry.id)",
            leading: .init(key: entry.id, size: BackgroundColours.size) { AnyView(BackgroundColours(entry: entry)) },
            title: entry.name,
            detail: gone ? "Removed" : "",
            dimmed: gone,
            actions: (gone ? [] : [
                SettingsAction(title: up ? "In Use" : "Use", icon: up ? "checkmark" : "paintbrush", key: "use") {
                    if !up { background.set(entry) }
                },
            ]) + [
                gone
                    ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { [weak self] in self?.pending.remove(entry.id) }
                    : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { [weak self] in self?.pending.insert(entry.id) },
            ]))
    }

    private static func reason(_ background: BackgroundStore) -> String {
        guard background.shown != nil else { return "Until a title is picked" }
        switch background.source {
        case .home: return "From Home"
        case .saved: return "From Saved"
        case .chosen: return "Chosen by you"
        }
    }

    private static func launchDetail(_ choice: BackgroundPicks.AtLaunch) -> String {
        switch choice {
        case .home: "A title on Home, a new one each launch."
        case .saved: "One of your saved ones, never twice running."
        case .never: "The one up now stays."
        }
    }
}


/// Home & Details, one card: Trailers, Auto-Advance, Hide Spoilers, Hide
/// Watched, Continue Watching Order, then Your Rows and For You (pages).
private final class HomeSettingsPage: UISettingsPage {
    private static let defaults = UserDefaults.standard

    override func setUp() {
        watch(env.home)
        watch(DiscoverPins.shared)
        watchDefaults()
    }

    private func flag(_ key: String, _ fallback: Bool) -> Bool {
        Self.defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func set(_ key: String) -> (Bool) -> Void {
        { [weak self] in Self.defaults.set($0, forKey: key); self?.changed() }
    }

    override func sections() -> [UISettingsSection] {
        let settings = env.home
        let trailers = !settings.heroTrailersEnabled ? "off" : settings.heroTrailerSound ? "sound" : "silent"
        // One card, by how often it's changed, the related side by side:
        // what moves, what's hidden, the rows (their pages last).
        return [UISettingsSection(rows: [
            .choice(.init(
                id: "h.trailers", title: "Trailers",
                options: [
                    SettingsOption(id: "off", label: "Off", detail: "The pictures stay still."),
                    SettingsOption(id: "silent", label: "Silent",
                                   detail: "On the billboard, Details and the cards, when you rest; muted."),
                    SettingsOption(id: "sound", label: "With Sound",
                                   detail: "On the billboard, Details and the cards, when you rest; with sound."),
                ],
                selection: trailers) { pick in
                    settings.heroTrailersEnabled = pick != "off"
                    if pick != "off" { settings.heroTrailerSound = pick == "sound" }
                }),
            .onOff(id: "h.advance", title: "Auto-Advance Billboard",
                   description: "The next title every \(Int(BillboardAutoPage.interval)) seconds.",
                   isOn: flag(BillboardAutoPage.key, true), set: set(BillboardAutoPage.key)),
            .onOff(id: "h.spoilers", title: "Hide Spoilers",
                   description: "Blurs the pictures of episodes you haven't watched, on Home and in Details.",
                   isOn: flag(DetailHideSpoilers.key, false), set: set(DetailHideSpoilers.key)),
            .onOff(id: "h.hide", title: "Hide Watched Titles",
                   description: "Watched films and finished shows stay out of the rows.",
                   isOn: flag(HomeHideWatched.key, false), set: set(HomeHideWatched.key)),
            .choice(.init(
                id: "h.order", title: "Continue Watching Order",
                options: [
                    SettingsOption(id: ContinueWatchingSortMode.recentlyWatched.rawValue, label: "Last Watched",
                                   detail: "What you watched last comes first."),
                    SettingsOption(id: ContinueWatchingSortMode.streamingStyle.rawValue, label: "In Progress First",
                                   detail: "Started titles first, next episodes after."),
                ],
                selection: settings.continueWatchingSortMode.rawValue) {
                    settings.continueWatchingSortMode = ContinueWatchingSortMode(rawValue: $0) ?? .recentlyWatched
                }),
            .link(.init(id: "h.yourRows", title: "Your Rows", description: "Your sentences from Discover, as rows on Home.",
                        value: "\(DiscoverPins.shared.all.count) of \(DiscoverPins.limit)") { [weak self] in
                guard let host = self?.host else { return }
                host.open(YourRowsSettingsPage(host: host))
            }),
            .link(.init(id: "h.forYou", title: "For You",
                        description: "What Cue learns from your watching, and why each row on Home is there.") { [weak self] in
                guard let host = self?.host else { return }
                host.open(ForYouSettingsPage(host: host))
            }),
        ])]
    }
}

/// Your Rows: Add from Discover on top (a plus to the tab; at the most,
/// the count), then each sentence in its order: Open in Discover, Move,
/// Rename, Remove (undo in place until the page is left).
private final class YourRowsSettingsPage: UISettingsPage {
    override var title: String? { "Your Rows" }
    private var moving: String? { didSet { TopBarLock.shared.locked = moving != nil; changed() } }
    private var pending: Set<String> = [] { didSet { changed() } }

    override func setUp() { watch(DiscoverPins.shared) }

    override func disappeared() {
        for id in pending { DiscoverPins.shared.remove(id) }
        pending = []
        moving = nil
    }

    override func sections() -> [UISettingsSection] {
        let pins = DiscoverPins.shared
        let rows = pins.all
        let count = rows.count - pending.count
        let room = DiscoverPins.limit - count
        let header: UISettingsRow = .actions(.init(
            id: "yr.add",
            title: room > 0 ? "Add from Discover" : "\(count) of \(DiscoverPins.limit) Rows",
            detail: room <= 0 ? "Remove one to add another."
                : rows.isEmpty ? "In Discover, Add to Home puts a sentence on Home."
                : room == 1 ? "1 more can be added." : "\(room) more can be added.",
            actions: room > 0 ? [SettingsAction(title: "Add from Discover", icon: "plus", key: "add") {
                pins.showDiscover.send()
            }] : []))
        return [UISettingsSection(rows: [header] + rows.map { pin in
            let gone = pending.contains(pin.id)
            let name = pin.rowName
            return .actions(.init(
                id: "h.pin.\(pin.id)", title: name,
                detail: gone ? "Removed" : DiscoverPins.titleCase(pin.name) == name ? "" : pin.name,
                dimmed: gone,
                actions: actions(pin, name: name, gone: gone, count: rows.count),
                moving: moving == pin.id, anyMoving: moving != nil,
                onMove: { pins.move(pin.id, by: $0) },
                onDrop: { [weak self] in self?.moving = nil }))
        })]
    }

    private func actions(_ pin: DiscoverPins.Pin, name: String, gone: Bool, count: Int) -> [SettingsAction] {
        let pins = DiscoverPins.shared
        var list: [SettingsAction] = []
        if !gone {
            list.append(SettingsAction(title: "Open in Discover", icon: "safari", key: "open") { pins.opening = pin })
            if count > 1 {
                list.append(SettingsAction(title: "Move", icon: "arrow.up.arrow.down", move: true, key: "move") { [weak self] in
                    self?.moving = pin.id
                })
            }
            list.append(SettingsAction(title: "Rename", icon: "pencil", key: "rename") { [weak self] in
                self?.host.keyboard.ask(text: name, placeholder: DiscoverPins.titleCase(pin.name)) { pins.rename(pin.id, to: $0) }
            })
        }
        list.append(gone
            ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { [weak self] in self?.pending.remove(pin.id) }
            : SettingsAction(title: "Remove from Home", icon: "trash", danger: true, key: "remove") { [weak self] in
                self?.pending.insert(pin.id)
            })
        return list
    }
}

private final class PlaybackSettingsPage: UISettingsPage {
    override func setUp() { watch(env.player) }

    override func sections() -> [UISettingsSection] {
        let store = env.player
        let settings = store.settings
        let language = settings.language.isEmpty ? "Device Language"
            : PlayerSettings.languages(including: settings.language).first { $0.code == settings.language }?.name
                ?? settings.language
        let description = "For audio and subtitles. A track you pick in the player is kept."
        // Everything else is chosen in the player.
        return [UISettingsSection(rows: [
            // Many languages: their own page.
            .link(.init(id: "p.language", title: "Language", description: description, value: language) { [weak self] in
                guard let host = self?.host else { return }
                host.open(UIOptionsPage(
                    host: host, title: "Language",
                    options: [SettingsOption(id: "", label: "Device Language")]
                        + PlayerSettings.languages(including: settings.language).map { SettingsOption(id: $0.code, label: $0.name) },
                    selection: settings.language) { store.settings.language = $0 })
            }),
            .choice(.init(
                id: "p.original", title: "Original Audio",
                options: [
                    SettingsOption(id: PlayerSettings.OriginalAudio.off.rawValue, label: "Off",
                                   detail: "Audio in your language where there is some."),
                    SettingsOption(id: PlayerSettings.OriginalAudio.anime.rawValue, label: "Anime",
                                   detail: "Anime in Japanese, the rest in your language."),
                    SettingsOption(id: PlayerSettings.OriginalAudio.all.rawValue, label: "All Titles",
                                   detail: "Every title in the language it was made in."),
                ],
                selection: settings.originalAudio.rawValue) { store.settings.originalAudio = PlayerSettings.OriginalAudio(rawValue: $0) ?? .off }),
            .choice(.init(
                id: "p.subtitles", title: "Subtitles",
                options: [
                    SettingsOption(id: PlayerSettings.Subtitles.off.rawValue, label: "Off",
                                   detail: "None until you turn them on in the player."),
                    SettingsOption(id: PlayerSettings.Subtitles.auto.rawValue, label: "Auto",
                                   detail: "When the audio isn't your language; else only forced ones."),
                    SettingsOption(id: PlayerSettings.Subtitles.always.rawValue, label: "Always",
                                   detail: "In your language, whatever the audio."),
                ],
                selection: settings.subtitles.rawValue) { store.settings.subtitles = PlayerSettings.Subtitles(rawValue: $0) ?? .auto }),
            // How the sources read, before and while playing (from Appearance, 2026-11-23).
            .choice(.init(
                id: "p.sources", title: "Source Cards", description: "How links read when you pick a source.",
                options: [
                    SettingsOption(id: SourceCardStyle.raw.rawValue, label: "Raw",
                                   detail: "The add-on's own text, as it sends it."),
                    SettingsOption(id: SourceCardStyle.styled.rawValue, label: "Styled",
                                   detail: "Quality, size and audio, read from the file name."),
                ],
                selection: SourceCardStyle.current.rawValue) { [weak self] in
                    UserDefaults.standard.set($0, forKey: SourceCardStyle.key)
                    self?.changed()
                }),
        ])]
    }
}

/// Storage (every bin red): a row each for the cache and the search
/// history, its summary and Clear on it, its page one press away; then
/// what's free.
private final class StorageSettingsPage: UISettingsPage {
    override func setUp() {
        watch(CacheMeter.shared)
        watch(env.search)
    }

    override func appeared() { Task { await CacheMeter.shared.measure() } }

    override func sections() -> [UISettingsSection] {
        let cache = CacheMeter.shared
        let search = env.search
        return [UISettingsSection(rows: [
            .actions(.init(id: "s.cache", title: "Cache", detail: cache.summary(" · Loads again as needed"), actions: [
                SettingsAction(title: "Show Cache", icon: "list.bullet", key: "more") { [weak self] in
                    guard let host = self?.host else { return }
                    host.open(UICachePage(host: host))
                },
                SettingsAction(title: "Clear Cache", icon: "trash", danger: true, key: "clear") { cache.clear() },
            ])),
            isHeld("search")
            ? .actions(.init(id: "s.search", title: "Search History", detail: "Cleared when you leave", dimmed: true,
                             actions: [Self.undoAction("clear") { [weak self] in self?.undo("search") }]))
            : .actions(.init(id: "s.search", title: "Search History", detail: Self.historyDetail(search),
                           actions: search.hasHistory ? [
                SettingsAction(title: "Show Search History", icon: "list.bullet", key: "more") { [weak self] in
                    guard let host = self?.host else { return }
                    host.open(UISearchHistoryPage(host: host))
                },
                SettingsAction(title: "Clear Search History", icon: "trash", danger: true, key: "clear") { [weak self] in
                    self?.hold("search") { search.clearHistory() }
                },
            ] : [])),
            .info(title: "Free on This Apple TV", value: cache.free.map(CachePage.size) ?? "—"),
        ])]
    }

    static func historyDetail(_ search: SearchViewModel) -> String {
        let searches = search.recentSearches.count, titles = search.recentTitles.count
        guard searches + titles > 0 else { return "Empty" }
        return [searches > 0 ? (searches == 1 ? "1 search" : "\(searches) searches") : nil,
                titles > 0 ? (titles == 1 ? "1 title" : "\(titles) titles") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private final class AboutSettingsPage: UISettingsPage {
    override func sections() -> [UISettingsSection] {
        [
            // One card: the two to press first, then what's only to read.
            UISettingsSection(rows: [
                .link(.init(id: "b.privacy", title: "Privacy", description: "Cue collects nothing about you.") { [weak self] in
                    guard let host = self?.host else { return }
                    host.open(UIPrivacyPage(host: host))
                }),
                .link(.init(id: "b.licenses", title: "Licenses & Credits",
                            description: "Free software under the GPLv3, and what it's built with.") { [weak self] in
                    guard let host = self?.host else { return }
                    host.open(UILicensesPage(host: host))
                }),
                .info(title: "Version", value: DiagnosticsService.appVersion),
                .info(title: "Source Code", value: DiagnosticsService.sourceAddress),
                .info(title: "Device", value: DiagnosticsService.deviceName),
                .info(title: "Software", value: DiagnosticsService.systemVersion),
            ]),
        ]
    }
}

private final class DeveloperSettingsPage: UISettingsPage {
    private var logOn = ProbeGate.isEnabled
    private var sessionCount: Int?

    override func appeared() {
        sessionCount = CueLog.sessionCount()
        changed()
    }

    override func setUp() { watch(PerformanceSettingsStore.shared) }

    override func sections() -> [UISettingsSection] {
        let store = PerformanceSettingsStore.shared
        var log: [UISettingsRow] = [
            .onOff(id: "d.log", title: "Log", description: "What the app does, to a file here, a week at most.",
                   isOn: logOn) { [weak self] in
                self?.logOn = $0
                ProbeGate.store($0)
                self?.changed()
            },
            .link(.init(id: "d.sessions", title: "Sessions", value: sessionCount.map(String.init)) { [weak self] in
                guard let self else { return }
                self.host.open(UILogSessionsPage(host: self.host))
            }),
        ]
        if logOn, let address = LogServer.address { log.append(.info(title: "Address", value: address)) }
        return [
            UISettingsSection(label: "Overlays", rows: [
                .choice(.init(
                    id: "d.fps", title: "Frame Rate",
                    options: [
                        SettingsOption(id: "off", label: "Off", detail: "No counter."),
                        SettingsOption(id: "compact", label: "Compact", detail: "Frames per second, top right."),
                        SettingsOption(id: "full", label: "Full", detail: "Adds frame times, CPU and memory."),
                    ],
                    selection: store.settings.frameRate.rawValue) {
                        store.settings.frameRate = PerformanceSettingsStore.FrameRate(rawValue: $0) ?? .off
                    }),
                .onOff(id: "d.hud", title: "Playback HUD", description: "Live numbers over the video: decoding, drops, bitrate.",
                       isOn: store.settings.showPlaybackHUD) { store.settings.showPlaybackHUD = $0 },
            ]),
            UISettingsSection(label: "Log", rows: log),
        ]
    }
}

// MARK: The pages rows open

/// A list of titles to open or remove (Watch Progress, Library, Watched):
/// Remove All on top (confirmed), then a row per title, its poster, name
/// and detail, at its end Open (its Details), one more (a show's
/// Episodes) and the bin. A removal stays in place, faded, its bin an undo
/// arrow: it reaches the account only as you leave the page.
private class UIRemovableListPage: UISettingsPage {
    struct Item {
        let id: String
        let poster: String?
        let name: String
        let detail: String
        let meta: MetaItem?
        var more: SettingsAction? = nil
    }

    var items: [Item] { [] }
    var ready: Bool { true }
    var empty: String { "" }
    /// The top row's name for the count, and what the list is for under it.
    func count(_ n: Int) -> String { n == 1 ? "1 Title" : "\(n.formatted()) Titles" }
    var summary: String { "" }
    func remove(_ id: String) {}
    func removeAll() {}

    private var pending: Set<String> = [] { didSet { changed() } }

    override func disappeared() {
        if !pending.isEmpty, pending.count == items.count { removeAll() } else { for id in pending { remove(id) } }
        pending = []
    }

    override func sections() -> [UISettingsSection] {
        guard ready else { return [] }
        let items = items
        guard !items.isEmpty else { return [UISettingsSection(rows: [.note(empty)])] }
        // One card: a row for them all (the count, Remove All), then each.
        let header: UISettingsRow = .actions(.init(
            id: "remove-all", title: count(items.count - pending.count), detail: summary,
            actions: [pending.count == items.count
                ? Self.undoAction("all", spelled: true, title: "Undo All") { [weak self] in self?.pending = [] }
                : SettingsAction(title: "Remove All", icon: "trash", danger: true, key: "all", spelled: true) { [weak self] in
                    self?.pending = Set(items.map(\.id))
                }]))
        return [
            UISettingsSection(rows: [header] + items.map { item in
                let gone = pending.contains(item.id)
                var actions: [SettingsAction] = []
                if let meta = item.meta, let open = env.openTitle, !gone {
                    actions.append(SettingsAction(title: "Open", icon: "info.circle", key: "open") { open(meta) })
                }
                if let more = item.more, !gone { actions.append(more) }
                // One key both ways: focus stays on it as it turns.
                actions.append(gone
                    ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { [weak self] in self?.pending.remove(item.id) }
                    : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { [weak self] in self?.pending.insert(item.id) })
                return .actions(.init(id: item.id, leading: .poster(item.poster), title: item.name,
                                      detail: gone ? "Removed" : item.detail, dimmed: gone, actions: actions))
            }),
        ]
    }
}

private final class UIWatchProgressPage: UIRemovableListPage {
    override var title: String? { "Watch Progress" }
    override func setUp() { watch(env.progress) }
    override var items: [Item] {
        env.progress.items.values.sorted { $0.updatedAt > $1.updatedAt }.map {
            Item(id: $0.id, poster: $0.poster, name: $0.name.isEmpty ? $0.metaID : $0.name,
                 detail: WatchProgressPage.detail(of: $0),
                 meta: MetaItem(id: $0.metaID, type: $0.type, name: $0.name, poster: $0.poster, background: $0.background))
        }
    }
    override var empty: String { "Nothing in progress." }
    override func count(_ n: Int) -> String { n == 1 ? "1 Title in Progress" : "\(n.formatted()) Titles in Progress" }
    override var summary: String { "Where you stopped, for Continue Watching." }
    override func remove(_ id: String) { env.progress.remove(id: id) }
    override func removeAll() { env.progress.clearAllProgress() }
}

private final class UILibraryPage: UIRemovableListPage {
    override var title: String? { "Library" }
    override func setUp() { watch(env.library) }
    private var saved: [SavedLibraryItem] { env.library.items.values.sorted { $0.addedAt > $1.addedAt } }
    override var items: [Item] {
        saved.map {
            Item(id: $0.key, poster: $0.poster, name: $0.name,
                 detail: "Added \($0.addedAt.formatted(.dateTime.day().month(.abbreviated).year()))", meta: $0.metaItem)
        }
    }
    override var empty: String { "Nothing saved yet." }
    override func count(_ n: Int) -> String { n == 1 ? "1 Title Saved" : "\(n.formatted()) Titles Saved" }
    override var summary: String { "Saved for Later, on Home." }
    override func remove(_ id: String) {
        if let item = saved.first(where: { $0.key == id }) { env.library.remove(id: item.id, type: item.type) }
    }
    // One by one: `clearAll` is the account switch's, it queues no deletes.
    override func removeAll() { for item in saved { env.library.remove(id: item.id, type: item.type) } }
}

/// Watched: a row per title, newest first — a show's count and its last
/// episode, a film's date — Open, a show's Episodes, Remove.
private final class UIWatchedPage: UIRemovableListPage {
    override var title: String? { "Watched" }
    private var metas: [String: MetaItem] = [:]
    private var known: [String: String] = [:]
    private var loaded = false
    private var asked = false

    override func setUp() { watch(env.watched) }

    private var entries: [WatchedSettingsPage.Entry] {
        Dictionary(grouping: env.watched.items.values, by: \.contentID)
            .map { WatchedSettingsPage.Entry(id: $0.key, items: $0.value) }
            .sorted { $0.latest > $1.latest }
    }

    override func appeared() {
        guard !asked else { return }
        asked = true
        known = WatchedSettingsPage.knownNames(progress: env.progress, library: env.library)
        let wanted = entries.filter { metas[$0.id] == nil }.map { ($0.id, $0.type) }
        guard !wanted.isEmpty else { loaded = true; changed(); return }
        // Shown after 1.5 s at most, the names coming in as they're found.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.loaded else { return }
            self.loaded = true
            self.changed()
        }
        let addons = env.addons
        Task { [weak self] in
            await WatchedSettingsPage.resolveMetas(wanted, addonManager: addons) { id, meta in
                self?.metas[id] = meta
                if self?.loaded == true { self?.changed() }
            }
            self?.loaded = true
            self?.changed()
        }
    }

    override var ready: Bool { loaded }

    override var items: [Item] {
        entries.map { entry in
            let name = name(of: entry)
            let meta = metas[entry.id]
            return Item(id: entry.id, poster: meta?.poster, name: name, detail: detail(of: entry),
                        meta: meta ?? MetaItem(id: entry.id, type: entry.type, name: name),
                        more: entry.isShow ? SettingsAction(title: "Episodes", icon: "list.bullet") { [weak self] in
                            guard let self else { return }
                            self.host.open(UIWatchedEpisodesPage(host: self.host, id: entry.id, name: name, meta: meta))
                        } : nil)
        }
    }

    override var empty: String { "Nothing watched yet." }
    override var summary: String { "What you've finished, and episodes as you watch them." }
    override func remove(_ id: String) {
        if let entry = entries.first(where: { $0.id == id }) { env.watched.remove(keys: entry.items.map(\.key)) }
    }
    override func removeAll() {
        if let sync = NuvioSyncManager.shared {
            Task { await sync.clearWatchHistoryEverywhere() }
        } else {
            env.watched.clearAll()
        }
    }

    private func name(of entry: WatchedSettingsPage.Entry) -> String {
        if let name = metas[entry.id]?.name, !name.isEmpty { return name }
        if let name = known[entry.id] { return name }
        if !entry.isShow, let film = entry.items.first, !film.title.isEmpty { return film.title }
        return entry.id
    }

    /// "12 episodes · S2:E4, 14 Oct 2026"; a film its date.
    private func detail(of entry: WatchedSettingsPage.Entry) -> String {
        let date = entry.latest.formatted(.dateTime.day().month(.abbreviated).year())
        guard entry.isShow, let last = entry.items.max(by: { $0.watchedAt < $1.watchedAt }) else { return date }
        let count = entry.items.filter { $0.episode != nil }.count
        return "\(count == 1 ? "1 episode" : "\(count) episodes") · S\(last.season ?? 0):E\(last.episode ?? 0), \(date)"
    }
}

/// A show's watched episodes: Remove All (the show's, confirmed), then a
/// section per season, a row per episode, its bin (undone in place).
private final class UIWatchedEpisodesPage: UISettingsPage {
    private let id: String
    private let name: String
    private let meta: MetaItem?
    private var pending: Set<String> = [] { didSet { changed() } }

    init(host: CardSettingsController, id: String, name: String, meta: MetaItem?) {
        self.id = id
        self.name = name
        self.meta = meta
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { name }
    override func setUp() { watch(env.watched) }

    override func disappeared() {
        if !pending.isEmpty { env.watched.remove(keys: Array(pending)) }
        pending = []
    }

    private var items: [WatchedItem] {
        env.watched.items.values.filter { $0.contentID == id }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    override func sections() -> [UISettingsSection] {
        let items = items
        guard !items.isEmpty else { return [UISettingsSection(rows: [.note("No episodes watched.")])] }
        let seasons = Dictionary(grouping: items) { $0.season ?? 0 }.sorted { $0.key < $1.key }
        // A card per season: a row for it (the count, Remove All: the whole
        // show is removed a level up, on its row), then its episodes.
        return seasons.map { season, episodes in
            let seasonName = season == 0 ? "Specials" : "Season \(season)"
            let left = episodes.filter { !pending.contains($0.key) }.count
            // Its name over the card; the top row how many, and when last.
            let last = episodes.filter { !pending.contains($0.key) }.map(\.watchedAt).max()
            let header: UISettingsRow = .actions(.init(
                id: "season-\(season)", title: left == 1 ? "1 Episode Watched" : "\(left) Episodes Watched",
                detail: last.map { "Last on " + $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "All removed",
                actions: [left == 0
                    ? Self.undoAction("all", spelled: true, title: "Undo All") { [weak self] in
                        self?.pending.subtract(episodes.map(\.key))
                    }
                    : SettingsAction(title: "Remove All", icon: "trash", danger: true, key: "all", spelled: true) { [weak self] in
                        self?.pending.formUnion(episodes.map(\.key))
                    }]))
            return UISettingsSection(label: seasonName, rows: [header] + episodes.map { item in
                let gone = pending.contains(item.key)
                return .actions(.init(
                    id: item.key, title: title(of: item),
                    detail: gone ? "Removed" : item.watchedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()),
                    dimmed: gone,
                    actions: [gone
                        ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { [weak self] in self?.pending.remove(item.key) }
                        : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { [weak self] in self?.pending.insert(item.key) }]))
            })
        }
    }

    /// "E3: Episode title", else "E3".
    private func title(of item: WatchedItem) -> String {
        let number = "E\(item.episode ?? 0)"
        let video = meta?.videos?.first { $0.season == item.season && $0.episode == item.episode }
        let title = video?.title ?? (item.title == name || item.title == meta?.name ? "" : item.title)
        return title.isEmpty ? number : "\(number): \(title)"
    }
}

/// The profile's recent searches and the titles opened from Search: a row
/// each, Remove (undo in place), the titles Open too.
private final class UISearchHistoryPage: UISettingsPage {
    private var pending: Set<String> = [] { didSet { changed() } }

    override var title: String? { "Search History" }
    override func setUp() { watch(env.search) }

    override func disappeared() {
        for key in pending {
            if key.hasPrefix("q.") { env.search.forgetSearch(String(key.dropFirst(2))) }
            else { env.search.forgetTitle(String(key.dropFirst(2))) }
        }
        pending = []
    }

    private func remove(_ key: String, gone: Bool) -> SettingsAction {
        gone
            ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { [weak self] in self?.pending.remove(key) }
            : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { [weak self] in self?.pending.insert(key) }
    }

    /// A card's top row: its name and count, Remove All (Undo All once
    /// they're all removed).
    private func header(_ id: String, _ title: String, _ detail: String, keys: [String]) -> UISettingsRow {
        let all = keys.allSatisfy { pending.contains($0) }
        return .actions(.init(id: id, title: title, detail: detail, actions: [all
            ? Self.undoAction("all", spelled: true, title: "Undo All") { [weak self] in self?.pending.subtract(keys) }
            : SettingsAction(title: "Remove All", icon: "trash", danger: true, key: "all", spelled: true) { [weak self] in
                self?.pending.formUnion(keys)
            }]))
    }

    override func sections() -> [UISettingsSection] {
        let search = env.search
        var sections: [UISettingsSection] = []
        if !search.hasHistory { sections.append(UISettingsSection(rows: [.note("Nothing yet.")])) }
        // A card each under its name: how many and Remove All on top, then each.
        let searches = search.recentSearches.map { "q." + $0 }
        if !searches.isEmpty {
            let left = searches.filter { !pending.contains($0) }.count
            sections.append(UISettingsSection(label: "Recent Searches", rows: [
                header("s.searches", left == 1 ? "1 Search" : "\(left) Searches",
                       "What you typed, offered again in Search.", keys: searches),
            ] + search.recentSearches.map { query in
                let key = "q." + query
                let gone = pending.contains(key)
                return .actions(.init(id: key, title: query, detail: gone ? "Removed" : "", dimmed: gone,
                                      actions: [remove(key, gone: gone)]))
            }))
        }
        let titles = search.recentTitles.map { "t." + $0.id }
        if !titles.isEmpty {
            let left = titles.filter { !pending.contains($0) }.count
            sections.append(UISettingsSection(label: "Opened from Search", rows: [
                header("s.titles", left == 1 ? "1 Title" : "\(left) Titles",
                       "Shown in Search before you type.", keys: titles),
            ] + search.recentTitles.map { item in
                let key = "t." + item.id
                let gone = pending.contains(key)
                let open = env.openTitle
                return .actions(.init(
                    id: key, leading: .poster(item.poster), title: item.name,
                    detail: gone ? "Removed" : item.type == "movie" ? "Movie" : "Series", dimmed: gone,
                    actions: (gone || open == nil ? [] : [
                        SettingsAction(title: "Open", icon: "info.circle", key: "open") { open?(item) },
                    ]) + [remove(key, gone: gone)]))
            }))
        }
        return sections
    }
}

/// Every cache by kind, its size and allowance, to read; Clear on top.
private final class UICachePage: UISettingsPage {
    override var title: String? { "Cache" }
    override func setUp() { watch(CacheMeter.shared) }

    override func sections() -> [UISettingsSection] {
        let cache = CacheMeter.shared
        return [UISettingsSection(rows: [
            .actions(.init(id: "c.all", title: "Cache", detail: cache.summary(" · Your account and settings stay"), actions: [
                SettingsAction(title: "Clear Cache", icon: "trash", danger: true, key: "clear") { cache.clear() },
            ])),
        ] + (cache.parts ?? []).map { .info(title: $0.name, value: Self.value($0)) })]
    }

    private static func value(_ part: CacheStorage.Part) -> String {
        guard let limit = part.limit else { return CachePage.size(part.bytes) }
        let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
        return part.bytes == 0 ? "Empty, up to \(limitText)" : "\(CachePage.size(part.bytes)) of \(limitText)"
    }
}

/// Many choices (languages): one row each, the current one checked —
/// Select picks it, the page stays.
private final class UIOptionsPage: UISettingsPage {
    private let name: String
    private let options: [SettingsOption]
    private var selection: String
    private let onPick: (String) -> Void

    init(host: CardSettingsController, title: String, options: [SettingsOption], selection: String,
         onPick: @escaping (String) -> Void) {
        name = title
        self.options = options
        self.selection = selection
        self.onPick = onPick
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { name }

    override func sections() -> [UISettingsSection] {
        [UISettingsSection(rows: options.map { option in
            .link(.init(id: option.id, title: option.label,
                        leading: option.leading.map { view in .init(key: option.id) { view } },
                        checked: option.id == selection, chevron: false) { [weak self] in
                self?.selection = option.id
                self?.onPick(option.id)
                self?.changed()
            })
        })]
    }
}

/// The log's sessions, newest first: Clear Log, then a row each.
private final class UILogSessionsPage: UISettingsPage {
    private var sessions: [CueLog.Session]?

    override var title: String? { "Sessions" }

    override func appeared() {
        Task { [weak self] in
            self?.sessions = await CueLog.sessions()
            self?.changed()
        }
    }

    /// One card: how many and Clear All on top (every session but this
    /// one, when the page is left; Undo All till then), then each.
    override func sections() -> [UISettingsSection] {
        // At once: the count (the files, unread) and a word while they're read.
        guard let sessions else {
            let count = CueLog.sessionCount()
            return [UISettingsSection(rows: [
                .actions(.init(id: "log.all", title: count == 1 ? "1 Session" : "\(count) Sessions",
                               detail: "A week at most. This one is kept.", actions: [])),
                .note("Reading them…"),
            ])]
        }
        let clearing = isHeld("clear")
        let left = clearing ? sessions.filter(\.isCurrent).count : sessions.count
        let header: UISettingsRow = .actions(.init(
            id: "log.all", title: left == 1 ? "1 Session" : "\(left) Sessions",
            detail: "A week at most. This one is kept.",
            actions: sessions.count < 2 ? [] : [clearing
                ? Self.undoAction("all", spelled: true, title: "Undo All") { [weak self] in self?.undo("clear") }
                : SettingsAction(title: "Clear All", icon: "trash", danger: true, key: "all", spelled: true) { [weak self] in
                    self?.hold("clear") { CueLog.clear() }
                }]))
        return [UISettingsSection(rows: [header] + sessions.map { session in
            if clearing, !session.isCurrent {
                return .actions(.init(id: session.url.absoluteString, title: LogSessionsPage.title(session),
                                      detail: "Removed", dimmed: true, actions: []))
            }
            return .link(.init(id: session.url.absoluteString, title: LogSessionsPage.title(session),
                               value: LogSessionsPage.value(session)) { [weak self] in
                guard let self else { return }
                self.host.open(UILogSessionPage(host: self.host, session: session))
            })
        })]
    }
}

/// One session: what stood out in it, in order, its time on the right.
private final class UILogSessionPage: UISettingsPage {
    private let session: CueLog.Session

    init(host: CardSettingsController, session: CueLog.Session) {
        self.session = session
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { LogSessionsPage.title(session) }

    override func sections() -> [UISettingsSection] {
        [UISettingsSection(rows: session.notable.isEmpty
            ? [.info(title: "Nothing stood out", value: "")]
            : session.notable.map { .info(title: LogSessionPage.label($0), value: String($0.time.prefix(8))) })]
    }
}

/// Only to read: focus stays on the page, unseen.
/// Privacy, only to read: that nothing's collected, then each service Cue
/// talks to and what for, their policies' line under them.
private final class UIPrivacyPage: UISettingsPage {
    override var title: String? { "Privacy" }
    override func sections() -> [UISettingsSection] {
        [
            UISettingsSection(rows: [.info(title: "Cue collects nothing about you", value: "No analytics, no tracking")]),
            UISettingsSection(label: "What Cue Talks To", rows: [
                ("Nuvio", "Syncs your account"), ("TMDB", "Search, details and pictures"),
                ("MDBList", "Ratings, with your key"), ("Your Add-ons", "Titles and sources"), ("YouTube", "Trailers"),
            ].map { .info(title: $0.0, value: $0.1) } + [
                .note("What they receive is covered by their own privacy policies."),
            ]),
        ]
    }
}

/// Licenses & Credits, only to read and on one screen: Cue's licence, its
/// source and TMDB's notice (its terms ask for it, so it's never below the
/// fold), then what Cue is built with in two columns.
private final class UILicensesPage: UISettingsPage {
    override var title: String? { "Licenses & Credits" }
    static let parts = [
        ("AetherEngine", "LGPLv3"), ("FFmpeg", "LGPLv2.1"), ("libass", "ISC"), ("Inter", "SIL OFL 1.1"),
        ("FriBidi", "LGPLv2.1"), ("HarfBuzz", "MIT"), ("FreeType", "FTL"), ("Fontconfig", "MIT"),
        ("YouTubeKit", "MIT"), ("libdovi", "MIT"),
    ]
    override func sections() -> [UISettingsSection] {
        [
            UISettingsSection(rows: [
                .info(title: "Cue", value: "GNU GPL v3"),
                .info(title: "Source Code", value: DiagnosticsService.sourceAddress),
                .info(title: "TMDB", value: "Uses the TMDB API; not endorsed or certified by TMDB"),
            ]),
            UISettingsSection(label: "Built With", rows: [
                .hosted(.init(id: "lic.parts", key: "parts", readOnly: true) { AnyView(LicensesGrid(parts: Self.parts)) }),
            ]),
        ]
    }
}

/// What Cue is built with, two columns of name and licence, as the read-only
/// rows' words (the name medium, the licence at body).
private struct LicensesGrid: View {
    let parts: [(String, String)]

    var body: some View {
        let half = (parts.count + 1) / 2
        HStack(alignment: .top, spacing: 48) {
            column(Array(parts.prefix(half)))
            column(Array(parts.dropFirst(half)))
        }
        .padding(.horizontal, UISettings.rowInset)
        .padding(.vertical, UISettings.rowVertical)
    }

    private func column(_ items: [(String, String)]) -> some View {
        VStack(spacing: 22) {
            ForEach(items, id: \.0) { item in
                HStack {
                    Text(item.0).font(.system(size: UISettings.textSize, weight: .medium)).foregroundStyle(CueInk.primary)
                    Spacer(minLength: 12)
                    Text(item.1).font(.system(size: UISettings.textSize)).foregroundStyle(CueInk.body)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The add-ons, one page: Add Add-on and Refresh on top, then the add-ons
/// in source order, each a row with its actions on it: Configure (when it
/// has settings), Turn Off / On, Move, Rename, Remove.
private final class UIAddonsPage: UISettingsPage {
    private var moving: String? { didSet { TopBarLock.shared.locked = moving != nil; changed() } }
    private var refreshing = false
    private var failed = 0
    private static let refreshedKey = "cue.addons.refreshedAt"

    override var title: String? { "Add-ons" }
    override func setUp() { watch(env.addons) }
    override func disappeared() { moving = nil }

    private var refreshValue: String {
        if refreshing { return "Refreshing…" }
        if failed > 0 { return failed == 1 ? "1 didn't answer" : "\(failed) didn't answer" }
        let at = UserDefaults.standard.double(forKey: Self.refreshedKey)
        guard at > 0 else { return "Not refreshed yet" }
        return "Refreshed " + DateFormatter.settingsWhen.string(from: Date(timeIntervalSince1970: at))
    }

    override func sections() -> [UISettingsSection] {
        let manager = env.addons
        // One card: a row for them all (Refresh and Add on it, when they were
        // last refreshed, that the order counts), then each add-on.
        let header: UISettingsRow = .actions(.init(
            id: "a.header", title: manager.addons.count == 1 ? "1 Add-on" : "\(manager.addons.count) Add-ons",
            detail: manager.addons.isEmpty ? "Add one from your phone, with its link."
                : (manager.addons.count > 1 ? "Higher ones come first for sources · " : "") + refreshValue,
            actions: (manager.addons.isEmpty ? [] : [
                SettingsAction(title: "Refresh Add-ons", icon: "arrow.triangle.2.circlepath", key: "refresh") { [weak self] in
                    self?.refresh()
                },
            ]) + [
                SettingsAction(title: "Add Add-on", icon: "plus", key: "add") { [weak self] in
                    self?.host.present(AddonPhoneAddView(addonManager: manager) { self?.host.dismissPresented() })
                },
            ]))
        let rows: [UISettingsRow] = manager.addons.enumerated().map { index, addon in
            let held = "addon." + addon.id
            if isHeld(held) {
                return .actions(.init(
                    id: addon.id,
                    leading: .init(key: addon.id + (addon.manifest.logo ?? "") + "false") { AnyView(AddonLogo(addon: addon)) },
                    title: addon.displayName, detail: "Removed", dimmed: true,
                    actions: [Self.undoAction("remove") { [weak self] in self?.undo(held) }]))
            }
            return .actions(.init(
                id: addon.id,
                leading: .init(key: addon.id + (addon.manifest.logo ?? "") + "\(addon.enabled)") { AnyView(AddonLogo(addon: addon)) },
                title: addon.displayName, detail: AddonsCardPage.detail(addon), dimmed: !addon.enabled,
                actions: actions(addon),
                moving: moving == addon.id, anyMoving: moving != nil,
                onMove: { manager.move(addon, to: index + $0) },
                onDrop: { [weak self] in self?.moving = nil }))
        }
        let sections = [UISettingsSection(rows: [header] + rows)]
        return sections
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        changed()
        let manager = env.addons
        Task { [weak self] in
            let failed = await manager.refreshManifests(bypassCache: true)
            guard let self else { return }
            self.failed = failed
            self.refreshing = false
            if failed == 0 { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.refreshedKey) }
            self.changed()
        }
    }

    private func actions(_ addon: InstalledAddon) -> [SettingsAction] {
        let manager = env.addons
        var list: [SettingsAction] = []
        if addon.configureURL != nil {
            list.append(SettingsAction(title: "Configure", icon: "gearshape") { [weak self] in
                self?.host.present(AddonPhoneAddView(addonManager: manager, configuring: addon) { self?.host.dismissPresented() })
            })
        }
        list.append(SettingsAction(title: addon.enabled ? "Turn Off" : "Turn On",
                                   icon: addon.enabled ? "eye.slash" : "eye", key: "toggle") {
            manager.setEnabled(addon, !addon.enabled)
        })
        if manager.addons.count > 1 {
            list.append(SettingsAction(title: "Move", icon: "arrow.up.arrow.down", move: true) { [weak self] in
                self?.moving = addon.id
            })
        }
        list.append(SettingsAction(title: "Rename", icon: "pencil") { [weak self] in
            self?.host.keyboard.ask(text: addon.displayName, placeholder: addon.manifest.name) { manager.rename(addon, to: $0) }
        })
        list.append(SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { [weak self] in
            self?.hold("addon." + addon.id) { manager.remove(addon) }
        })
        return list
    }
}

/// A PIN's steps over everything (set, check the current, a new one),
/// gone when they are.
private struct ProfilePinFlow: View {
    let profile: UserProfile
    @State var step: ProfilePinStep?
    let onDone: () -> Void

    var body: some View {
        Group {
            if let step { ProfilePinEntry(profile: profile, current: step, step: $step) } else { Color.clear }
        }
        .onChange(of: step == nil) { _, done in if done { onDone() } }
    }
}

/// A profile: its top row (the avatar to press for its page, the name,
/// Switch and Delete), Name, the PIN, Use Primary's Add-ons; then Copy
/// Settings in place (from whom, which parts, Copy).
private final class UIProfileEditPage: UISettingsPage {
    private let profileID: Int
    /// Over the gate: no Switch row (picking switches).
    private let fromGate: Bool
    private var copy: ProfileSetupCopy?
    private var copying = false

    init(host: CardSettingsController, profileID: Int, fromGate: Bool = false) {
        self.profileID = profileID
        self.fromGate = fromGate
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { "Edit Profile" }
    override func setUp() { watch(env.profiles) }

    override func appeared() {
        let profiles = env.profiles
        Task { await profiles.loadAvatarCatalog() }
    }

    override func sections() -> [UISettingsSection] {
        let profiles = env.profiles
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return [] }
        let primary = profile.id == 1
        let active = profile.id == profiles.activeProfileID
        let notes = profiles.notes(for: profile)
        let env = env
        var actions: [SettingsAction] = []
        if !active, !fromGate {
            actions.append(SettingsAction(title: "Switch to This Profile", icon: "arrow.right.circle", key: "switch") { [weak self] in
                self?.switchTo(profile)
            })
        }
        let deleting = isHeld("delete")
        if deleting {
            actions = [Self.undoAction("delete") { [weak self] in self?.undo("delete") }]
        } else if !primary {
            actions.append(SettingsAction(title: "Delete Profile", icon: "trash", danger: true, key: "delete") { [weak self] in
                self?.hold("delete") { profiles.delete(id: profile.id) }
            })
        }
        var rows: [UISettingsRow] = [
            .profile(.init(id: "pe.header", key: "\(profile.avatarColorHex)|\(profile.avatarID ?? "")|\(profile.name)",
                           title: profile.name, detail: deleting ? "Deleted when you leave" : notes, dimmed: deleting,
                           avatar: { env.wrap(ProfileAvatarView(profile: profile, size: UISettingsAvatarButton.size)) },
                           onAvatar: { [weak self] in
                               guard let self, !self.isHeld("delete") else { return }
                               self.host.open(UIProfileAvatarPage(host: self.host, profileID: profile.id))
                           },
                           actions: actions)),
            .link(.init(id: "pe.name", title: "Name", value: profile.name, chevron: false) { [weak self] in
                self?.host.keyboard.ask(text: profile.name, placeholder: "Profile name") { name in
                    let name = name.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { profiles.rename(id: profile.id, to: name) }
                }
            }),
        ]
        rows += profile.pinEnabled ? [
            .link(.init(id: "pe.pinChange", title: "Change PIN", description: "Asked before \(profile.name) opens.", chevron: false) { [weak self] in
                self?.pin(profile, .current(thenNew: true))
            }),
            .link(.init(id: "pe.pinRemove", title: "Remove PIN", chevron: false) { [weak self] in
                self?.pin(profile, .current(thenNew: false))
            }),
        ] : [
            .link(.init(id: "pe.pinSet", title: "Set PIN", description: "A 4-digit PIN before \(profile.name) opens.", chevron: false) { [weak self] in
                self?.pin(profile, .set)
            }),
        ]
        if !primary {
            rows.append(.onOff(id: "pe.primaryAddons", title: "Use Primary's Add-ons",
                               description: "Its add-ons instead of its own, kept in step.",
                               isOn: profile.usesPrimaryAddons) { profiles.setUsesPrimaryAddons(id: profile.id, $0) })
        }
        var sections = [UISettingsSection(rows: rows)]
        if profiles.profiles.count > 1 { sections.append(copySection(profile)) }
        return sections
    }

    /// Another profile's settings into this one, once: from whom (pills,
    /// a list past three, nothing with one), which parts (each On / Off), the
    /// keys' rule when keys go too, then Copy (Undo until the page is left).
    private func copySection(_ target: UserProfile) -> UISettingsSection {
        let profiles = env.profiles
        let sources = profiles.profiles.filter { $0.id != target.id }
        let copy = copy ?? ProfileSetupCopy(source: sources.first?.id ?? 1, target: target.id)
        let from = sources.first { $0.id == copy.source }?.name ?? ""
        let options = sources.map { SettingsOption(id: "\($0.id)", label: $0.name) }
        let pick: (String) -> Void = { [weak self] id in
            var next = copy
            next.source = Int(id) ?? next.source
            self?.copy = next
            self?.changed()
        }
        // One other profile: no choice to show (the Copy row names it).
        var rows: [UISettingsRow] = options.count < 2 ? [] : [
            options.count <= 3
                ? .choice(.init(id: "cp.from", title: "From", options: options, selection: "\(copy.source)", onPick: pick))
                : .link(.init(id: "cp.from", title: "From", value: from) { [weak self] in
                    guard let self else { return }
                    self.host.open(UIOptionsPage(host: self.host, title: "Copy From", options: options,
                                                 selection: "\(copy.source)", onPick: pick))
                }),
        ]
        rows += [
            toggle("cp.tv", "TV Settings", "Cue's and NuvioTV's look, playback, subtitles and more.", copy, \.tv),
            toggle("cp.mobile", "Mobile Settings", "Nuvio Mobile's look, cards, playback and notifications.", copy, \.mobile),
            toggle("cp.desktop", "Desktop Settings", "Nuvio Desktop's look, cards, playback and notifications.", copy, \.desktop),
            toggle("cp.keys", "API Keys", "TMDB, MDBList, debrid, AnimeSkip and IntroDB; no sign-ins.", copy, \.keys),
        ]
        if copy.keys {
            rows.append(.onOff(id: "cp.replace", title: "Replace \(target.name)'s Keys",
                               description: "Keys only \(target.name) has are always kept.", isOn: copy.replaceKeys) { [weak self] on in
                var next = copy
                next.replaceKeys = on
                self?.copy = next
                self?.changed()
            })
        }
        let held = isHeld("copy")
        rows.insert(.actions(.init(
            id: "cp.copy",
            title: copying ? "Copying…" : "Copy from \(from) to \(target.name)",
            detail: held ? "Copied when you leave" : copy.isEmpty ? "Choose something to copy."
                : "Once: later changes stay separate.",
            actions: copying || (copy.isEmpty && !held) ? [] : [held
                ? Self.undoAction("copy", spelled: true) { [weak self] in self?.undo("copy") }
                : SettingsAction(title: "Copy", icon: "doc.on.doc", key: "copy", spelled: true) { [weak self] in
                    self?.hold("copy") { [weak self] in self?.run(copy) }
                },
            ])), at: 0)
        return UISettingsSection(label: "Copy Settings", rows: rows)
    }

    private func toggle(_ id: String, _ title: String, _ description: String, _ copy: ProfileSetupCopy,
                        _ part: WritableKeyPath<ProfileSetupCopy, Bool>) -> UISettingsRow {
        .onOff(id: id, title: title, description: description, isOn: copy[keyPath: part]) { [weak self] on in
            var next = copy
            next[keyPath: part] = on
            self?.copy = next
            self?.changed()
        }
    }

    private func run(_ copy: ProfileSetupCopy) {
        copying = true
        changed()
        let profiles = env.profiles
        Task { [weak self] in
            let failure = await profiles.copySetup(copy)
            guard let self else { return }
            self.copying = false
            self.changed()
            if let failure {
                ToastCenter.shared.show(failure, icon: "exclamationmark.triangle")
            } else {
                ToastCenter.shared.show("Settings copied", icon: "checkmark")
            }
        }
    }

    private func pin(_ profile: UserProfile, _ step: ProfilePinStep) {
        host.present(ProfilePinFlow(profile: profile, step: step) { [weak self] in self?.host.dismissPresented() })
    }

    private func switchTo(_ profile: UserProfile) {
        let profiles = env.profiles
        guard profile.pinEnabled else { profiles.setActive(profile.id); return }
        host.present(ProfilePinCheck(profile: profile) { [weak self] in
            self?.host.dismissPresented()
            profiles.setActive(profile.id)
        } onCancel: { [weak self] in self?.host.dismissPresented() })
    }
}

/// What a new profile is made of, kept until Create (nothing exists on the
/// account before: backing out leaves nothing behind).
@MainActor
final class NewProfileDraft {
    var name = ""
    var avatarID: String?
    /// nil: the free slot's colour.
    var colorHex: String?
    var pin: String?
    /// The titles it starts with, each a Love.
    var loves: [MetaItem] = []
    /// A profile whose settings it starts from (nil: fresh).
    var copyFrom: Int?
    /// What comes across from it (Copy Settings' parts): all of it by
    /// default, keys too (a profile with no TMDB key has no Home).
    var parts: ProfileSetupCopy = {
        var parts = ProfileSetupCopy(source: 0, target: 0)
        parts.keys = true
        return parts
    }()

    /// The parts copied, in words ("TV, Keys"; "Everything"; "Nothing").
    var partsSummary: String {
        let names = [(parts.tv, "TV"), (parts.mobile, "Mobile"), (parts.desktop, "Desktop"), (parts.keys, "Keys")]
            .filter(\.0).map(\.1)
        return names.count == 4 ? "Everything" : names.isEmpty ? "Nothing" : names.joined(separator: ", ")
    }
    var askedName = false

    /// The colour `addProfile` will give it (the first free slot's).
    func slotColour(_ profiles: ProfileStore) -> String {
        let used = Set(profiles.profiles.map(\.id))
        let id = (1...ProfileStore.maxProfiles).first { !used.contains($0) } ?? 1
        return ProfileStore.avatarColors[(id - 1) % ProfileStore.avatarColors.count]
    }

    func preview(_ profiles: ProfileStore) -> UserProfile {
        UserProfile(id: -1, name: name.isEmpty ? "New Profile" : name,
                    avatarColorHex: colorHex ?? slotColour(profiles), avatarID: avatarID)
    }
}

/// A new profile, a screen at a time, laid out as every page (the
/// controller draws where you are, the question, the profile so far and the
/// buttons): name, avatar, what it likes, whose settings to start from,
/// then a summary to check (each row back to its step) with the PIN, and
/// Create. The choices stay in the draft until then, so backing out leaves
/// nothing behind.
private final class UINewProfilePage: UISettingsPage {
    private enum Step { case name, avatar, taste, copy, pin, summary }
    /// The wizard's cards (the summary, what comes across): centred.
    static let cardWidth = CardSettingsController.summaryWidth

    private let draft = NewProfileDraft()
    private let fromGate: Bool
    private let onCreated: (UserProfile) -> Void
    private var step = Step.name
    private var creating = false
    private var titles: [MetaItem] = []
    private var tasteLoaded = false
    /// Opened from the summary: picking goes back there.
    private var reviewing = false

    init(host: CardSettingsController, fromGate: Bool, onCreated: @escaping (UserProfile) -> Void) {
        self.fromGate = fromGate
        self.onCreated = onCreated
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { "New Profile" }
    override func setUp() { watch(env.profiles) }

    /// A step with nothing to press on the page (the name, the PIN) leaves
    /// focus to its buttons: the page holding it, unseen, as Settings'
    /// pages do, trapped it (it reaches past the buttons).
    override var canBecomeFocused: Bool { false }

    /// The screens it has: Start From needs another profile and an account.
    private var steps: [Step] {
        let profiles = env.profiles
        var steps: [Step] = [.name, .avatar, .taste]
        if profiles.accountAvailable, !profiles.profiles.isEmpty { steps.append(.copy) }
        if profiles.accountAvailable { steps.append(.pin) }
        return steps + [.summary]
    }

    override func appeared() {
        let profiles = env.profiles
        Task { await profiles.loadAvatarCatalog() }
        loadTaste()
        changed()
        guard !draft.askedName else { return }
        draft.askedName = true
        // Keys and language come along by default: a profile with no TMDB
        // key has no Home. "Start Fresh" starts it bare.
        if profiles.accountAvailable, profiles.profiles.contains(where: { $0.id == 1 }) { draft.copyFrom = 1 }
        askName()
    }

    // MARK: Moving

    private func go(to next: Step) {
        step = next
        if next == .summary { reviewing = false }
        UIView.performWithoutAnimation { alpha = 0 }
        reset()
        host.setWizardLayout(next == .summary ? .summary : .plain)
        changed()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: Motion.fadeDuration) { self.alpha = 1 }
            self.host.refocusPage(buttons: next == .summary)
        }
        if next == .name { askName() } else { host.setChromeHidden(false) }
    }

    /// On to the next step, or back to the summary it was opened from.
    private func next() {
        if reviewing { go(to: .summary); return }
        let all = steps
        guard let i = all.firstIndex(of: step), i + 1 < all.count else { return }
        go(to: all[i + 1])
    }

    /// From the summary to a step, coming back once it's done.
    private func review(_ target: Step) {
        go(to: target)
        reviewing = true
    }

    override func handleBack() -> Bool {
        guard !creating else { return true }
        if reviewing { go(to: .summary); return true }
        let all = steps
        guard let i = all.firstIndex(of: step), i > 0 else { return false }
        go(to: all[i - 1])
        return true
    }

    // MARK: The name

    /// The keyboard at once, nothing of the name's screen under it as it
    /// comes in; the screen shows only if the keyboard goes with a name
    /// kept (Change Name, Continue).
    private func askName() {
        host.setChromeHidden(true)
        host.keyboard.ask(text: draft.name, placeholder: "Profile name") { [weak self] text in
            guard let self, self.step == .name else { return }
            let name = text.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                // Nothing typed, nothing before: no profile after all.
                if self.draft.name.isEmpty {
                    NotificationCenter.default.post(name: .gateEditorBack, object: nil)
                } else {
                    self.host.setChromeHidden(false)
                }
                return
            }
            self.draft.name = name
            self.next()
        }
    }

    // MARK: The titles

    /// A mix to like from: the best-known titles of the last twelve years
    /// in each kind of film and show (TMDB's discover by votes), a few
    /// each, films and shows taking turns, the kinds spread along the row
    /// (popular alone was this week's few, mostly one kind).
    private static let lanes: [(movie: Bool, query: [String: String])] = [
        (true, ["with_genres": "28"]),                                   // action
        (false, ["with_genres": "18"]),                                  // drama
        (true, ["with_genres": "35"]),                                   // comedy
        (false, ["with_genres": "80"]),                                  // crime
        (true, ["with_genres": "878"]),                                  // sci-fi
        (false, ["with_genres": "16", "with_original_language": "ja"]),  // anime
        (true, ["with_genres": "27"]),                                   // horror
        (false, ["with_genres": "35"]),                                  // comedy
        (true, ["with_genres": "16"]),                                   // animation
        (false, ["with_genres": "10765"]),                               // sci-fi & fantasy
        (true, ["with_genres": "10749"]),                                // romance
        (false, ["with_genres": "9648"]),                                // mystery
        (true, ["with_genres": "53"]),                                   // thriller
        (false, ["with_genres": "10759"]),                               // action & adventure
        (true, ["with_genres": "18"]),                                   // drama
        (false, ["with_genres": "99"]),                                  // documentary
        (true, ["with_genres": "14"]),                                   // fantasy
        (false, ["with_genres": "10751"]),                               // family
        (true, ["with_genres": "99"]),                                   // documentary
        (true, ["with_genres": "10751"]),                                // family
    ]

    private func loadTaste() {
        guard !tasteLoaded else { return }
        let since = "\(Calendar.current.component(.year, from: Date()) - 12)-01-01"
        Task { [weak self] in
            let lists = await withTaskGroup(of: (Int, [MetaItem]).self) { group in
                for (index, lane) in Self.lanes.enumerated() {
                    group.addTask {
                        var query = lane.query
                        query["sort_by"] = "vote_count.desc"
                        query[lane.movie ? "primary_release_date.gte" : "first_air_date.gte"] = since
                        let list = await TMDBService.cueList(lane.movie ? "/discover/movie" : "/discover/tv",
                                                             query: query, isMovie: lane.movie, limit: 8)
                        return (index, list.titles.map(\.item))
                    }
                }
                var lists = Array(repeating: [MetaItem](), count: Self.lanes.count)
                for await (index, items) in group { lists[index] = items }
                return lists
            }
            // Two rounds along the lanes: each lane's best not taken yet.
            var seen = Set<String>(), mixed: [MetaItem] = []
            for _ in 0..<2 {
                for list in lists {
                    guard let item = list.first(where: { !seen.contains($0.id) }) else { continue }
                    seen.insert(item.id)
                    mixed.append(item)
                }
            }
            self?.titles = mixed
            self?.tasteLoaded = true
            self?.changed()
        }
    }

    // MARK: The screens

    private func spelled(_ title: String, _ key: String, _ action: @escaping () -> Void) -> SettingsAction {
        SettingsAction(title: title, icon: "", key: key, spelled: true, action: action)
    }

    /// A profile (or the draft) as a round tile's face.
    private func face(_ profile: UserProfile) -> UISettingsRow.Tile.Face {
        if let url = env.profiles.avatarURL(for: profile) { return .avatar(url: url, name: profile.name) }
        return .colour(hex: profile.avatarColorHex, initial: profile.initial)
    }

    private func posters(_ id: String, _ label: String?, _ items: [MetaItem], picked: Set<String>) -> UISettingsSection {
        UISettingsSection(rows: [.posters(.init(id: id, title: label, items: items.map { item in
            .init(id: item.id, title: item.name,
                  detail: item.type == "movie" ? "Movie" : "Series",
                  poster: item.poster, on: picked.contains(item.id)) { [weak self] in
                guard let self else { return }
                if self.draft.loves.contains(where: { $0.id == item.id }) {
                    self.draft.loves.removeAll { $0.id == item.id }
                } else {
                    self.draft.loves.append(item)
                }
                self.changed()
            }
        }))], bare: true)
    }

    override func sections() -> [UISettingsSection] {
        let profiles = env.profiles
        let all = steps
        let index = all.firstIndex(of: step) ?? 0
        let name = draft.name
        let who = name.isEmpty ? "it" : name
        func chrome(_ heading: String, _ line: String?, _ buttons: [SettingsAction] = []) {
            host.setChrome(heading, line, step: index, count: all.count)
            host.setButtons(buttons)
            host.setPreview(step == .name ? nil : draft.preview(profiles))
        }
        switch step {
        case .name:
            chrome("What's your name?", "It's how this profile shows on Who's Watching.", name.isEmpty
                ? [spelled("Enter a Name", "name") { [weak self] in self?.askName() }]
                : [spelled("Change Name", "name") { [weak self] in self?.askName() },
                   spelled("Continue", "go") { [weak self] in self?.next() }])
            return []

        case .avatar:
            chrome("Pick an avatar", "Select one to go on.")
            let preview = draft.preview(profiles)
            // The preview follows focus; Select keeps it and goes on.
            func show(hex: String?, avatar: String?) {
                var shown = preview
                if let hex { shown.avatarColorHex = hex }
                shown.avatarID = avatar
                host.setPreview(shown)
            }
            let colours = ProfileStore.avatarColors.map { hex in
                UISettingsRow.Tile(id: "c." + hex, face: .colour(hex: hex, initial: preview.initial),
                                   chosen: draft.avatarID == nil && preview.avatarColorHex.uppercased() == hex.uppercased(),
                                   onFocus: { show(hex: hex, avatar: nil) }) { [weak self] in
                    self?.draft.colorHex = hex
                    self?.draft.avatarID = nil
                    self?.next()
                }
            }
            let kinds = AvatarChoices.groups(profiles.avatarCatalog).map { group in
                (name: group.name, tiles: group.items.map { item in
                    UISettingsRow.Tile(id: "a." + item.id, face: .avatar(url: item.imageURL, name: item.displayName),
                                       chosen: draft.avatarID == item.id,
                                       onFocus: { show(hex: nil, avatar: item.id) }) { [weak self] in
                        self?.draft.avatarID = item.id
                        self?.next()
                    }
                })
            }
            return [UISettingsSection(rows: [
                .tiles(.init(id: "np.avatars", groups: [(name: "Colours", tiles: colours)] + kinds, round: 120)),
            ], bare: true)]

        case .taste:
            let picked = Set(draft.loves.map(\.id))
            chrome("What do you like?", "Pick a few you love. Home starts from them.", [
                spelled(picked.isEmpty ? "Skip" : "Continue (\(picked.count))", "go") { [weak self] in self?.next() },
            ])
            guard !titles.isEmpty else {
                return [UISettingsSection(rows: [.note(tasteLoaded ? "Nothing to show: this profile has no TMDB key yet." : "Loading…")])]
            }
            return [posters("np.titles", nil, titles, picked: picked)]

        case .copy:
            // Select on a profile picks it and goes down to what comes
            // across; Start Fresh goes on. Continue once one is picked.
            chrome("Start from another profile?", "Choose what comes across, once. Never what it watched.",
                   draft.copyFrom == nil ? [] : [spelled("Continue", "go") { [weak self] in self?.next() }])
            var tiles: [UISettingsRow.Tile] = profiles.profiles.map { other in
                UISettingsRow.Tile(id: "cp.\(other.id)", face: face(other), chosen: draft.copyFrom == other.id,
                                   caption: other.name) { [weak self] in
                    guard let self else { return }
                    self.draft.copyFrom = other.id
                    self.changed()
                    if self.prefer(row: "cp.tv") { self.host.refocusPage() }
                }
            }
            tiles.append(UISettingsRow.Tile(id: "cp.none", face: .symbol("sparkles"), chosen: draft.copyFrom == nil,
                                            caption: "Start Fresh") { [weak self] in
                self?.draft.copyFrom = nil
                self?.next()
            })
            var sections = [UISettingsSection(rows: [.tiles(.init(id: "np.copy", groups: [(name: "", tiles: tiles)], round: 150))],
                                              bare: true)]
            if let source = draft.copyFrom.flatMap({ id in profiles.profiles.first { $0.id == id } }) {
                func part(_ id: String, _ title: String, _ description: String,
                          _ key: WritableKeyPath<ProfileSetupCopy, Bool>) -> UISettingsRow {
                    .onOff(id: id, title: title, description: description, isOn: draft.parts[keyPath: key]) { [weak self] on in
                        self?.draft.parts[keyPath: key] = on
                        self?.changed()
                    }
                }
                sections.append(UISettingsSection(label: "From \(source.name)", rows: [
                    part("cp.tv", "TV Settings", "Cue's and NuvioTV's look, playback, subtitles and more.", \.tv),
                    part("cp.mobile", "Mobile Settings", "Nuvio Mobile's look, cards, playback and notifications.", \.mobile),
                    part("cp.desktop", "Desktop Settings", "Nuvio Desktop's look, cards, playback and notifications.", \.desktop),
                    part("cp.keys", "API Keys", "TMDB, MDBList, debrid, AnimeSkip and IntroDB; no sign-ins. Without a TMDB key there's no Home.", \.keys),
                ], width: Self.cardWidth))
            }
            return sections

        case .pin:
            let locked = draft.pin != nil
            let setPin: () -> Void = { [weak self] in
                guard let self else { return }
                self.host.present(NewProfilePinFlow(name: who, onDone: { [weak self] pin in
                    self?.draft.pin = pin
                    self?.host.dismissPresented()
                    self?.next()
                }, onCancel: { [weak self] in self?.host.dismissPresented() }))
            }
            chrome("Lock this profile?", "A 4-digit PIN before \(who) opens. You can change it later in Edit Profile.", locked
                ? [spelled("Remove PIN", "off") { [weak self] in self?.draft.pin = nil; self?.changed() },
                   spelled("Change PIN", "set", setPin),
                   spelled("Continue", "go") { [weak self] in self?.next() }]
                : [spelled("Not Now", "go") { [weak self] in self?.draft.pin = nil; self?.next() },
                   spelled("Set a PIN", "set", setPin)])
            return [UISettingsSection(rows: [.hosted(.init(id: "np.lock", key: locked ? "on" : "off") {
                AnyView(VStack(spacing: 22) {
                    Circle()
                        .fill(FlatControl.rest)
                        .overlay {
                            Image(systemName: locked ? "lock.fill" : "lock.open")
                                .font(.system(size: 64, weight: .semibold))
                                .foregroundStyle(FlatControl.content)
                        }
                        .overlay { Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 2) }
                        .frame(width: 180, height: 180)
                    Text(locked ? "PIN set" : "No PIN")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(CueInk.color(FixedFocusText.secondary))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24))
            })], bare: true)]

        case .summary:
            chrome("Ready, \(who)?", "Check it over, then create it.", [
                spelled(creating ? "Creating…" : fromGate ? "Start Watching" : "Create Profile", "create") { [weak self] in
                    self?.create()
                },
            ])
            // Edit Profile's card: the profile on top (its avatar to press),
            // then what to change, each back to its step.
            let preview = draft.preview(profiles)
            let env = env
            let loves = draft.loves.count
            let sourceName = draft.copyFrom.flatMap { id in profiles.profiles.first { $0.id == id }?.name }
            var rows: [UISettingsRow] = [
                .profile(.init(id: "sm.header", key: "\(preview.avatarColorHex)|\(preview.avatarID ?? "")|\(preview.name)",
                               title: preview.name,
                               detail: sourceName.map { "New profile, from \($0)" } ?? "New profile",
                               avatar: { env.wrap(ProfileAvatarView(profile: preview, size: UISettingsAvatarButton.size)) },
                               onAvatar: { [weak self] in self?.review(.avatar) },
                               actions: [])),
                .link(.init(id: "sm.name", title: "Name", value: name, chevron: false) { [weak self] in
                    guard let self else { return }
                    self.host.keyboard.ask(text: self.draft.name, placeholder: "Profile name") { [weak self] text in
                        let text = text.trimmingCharacters(in: .whitespaces)
                        guard let self, !text.isEmpty else { return }
                        self.draft.name = text
                        self.changed()
                    }
                }),
                .link(.init(id: "sm.likes", title: "Likes", value: loves == 0 ? "None" : loves == 1 ? "1 title" : "\(loves) titles") { [weak self] in
                    self?.review(.taste)
                }),
            ]
            if all.contains(.copy) {
                rows.append(.link(.init(id: "sm.copy", title: "Starts From",
                                        value: sourceName.map { "\($0) · \(draft.partsSummary)" } ?? "Fresh") { [weak self] in
                    self?.review(.copy)
                }))
            }
            if all.contains(.pin) {
                rows.append(.link(.init(id: "sm.pin", title: "PIN", value: draft.pin == nil ? "Off" : "On") { [weak self] in
                    self?.review(.pin)
                }))
            }
            return [UISettingsSection(rows: rows)]
        }
    }

    // MARK: Create

    private func create() {
        guard !creating else { return }
        let name = draft.name
        guard !name.isEmpty else { review(.name); return }
        let profiles = env.profiles
        guard let created = profiles.addProfile(name: name) else {
            ToastCenter.shared.show("Can't add a profile just yet — try again in a moment",
                                    icon: "person.crop.circle.badge.exclamationmark")
            return
        }
        creating = true
        changed()
        if let avatar = draft.avatarID { profiles.setAvatar(id: created.id, avatarID: avatar) }
        else if let hex = draft.colorHex { profiles.setColor(id: created.id, hex: hex) }
        // Add-ons only supply streams: the primary's, until it picks its own.
        profiles.setUsesPrimaryAddons(id: created.id, true)
        TitleRatings.shared.seedStarter(draft.loves, for: created.id)
        let draft = draft
        Task { [weak self] in
            if let pin = draft.pin,
               case .failure(let message) = await profiles.setPin(id: created.id, pin: pin, currentPin: nil) {
                ToastCenter.shared.show("PIN not set — \(message)", icon: "lock.slash")
            }
            if let source = draft.copyFrom, !draft.parts.isEmpty {
                var copy = draft.parts
                copy.source = source
                copy.target = created.id
                if let failure = await profiles.copySetup(copy) {
                    ToastCenter.shared.show(failure, icon: "exclamationmark.triangle")
                }
            }
            let profile = profiles.profiles.first { $0.id == created.id } ?? created
            self?.onCreated(profile)
        }
    }
}

/// A new profile's PIN: twice, then it's kept until Create.
private struct NewProfilePinFlow: View {
    let name: String
    let onDone: (String) -> Void
    let onCancel: () -> Void
    @State private var first: String?

    var body: some View {
        if let first {
            PinEntryView(title: "Enter it again", subtitle: name,
                         onSubmit: { value in
                             guard value == first else { return "The PINs didn't match." }
                             onDone(value)
                             return nil
                         },
                         onCancel: { self.first = nil })
                .id("again")
        } else {
            PinEntryView(title: "Choose a 4-digit PIN", subtitle: name,
                         onSubmit: { value in first = value; return nil },
                         onCancel: onCancel)
                .id("first")
        }
    }
}

/// A profile's avatar: the initials on a colour, or one of the avatars, in
/// one card under a preview that stays put (its top, in its colour) while
/// the grid scrolls inside, so a pick shows at once.
private final class UIProfileAvatarPage: UISettingsPage {
    private let profileID: Int
    private var preview: UISettingsHosted?
    private static let previewHeight: CGFloat = 156

    init(host: CardSettingsController, profileID: Int) {
        self.profileID = profileID
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { "Avatar" }
    override func setUp() { watch(env.profiles) }

    override func appeared() {
        let profiles = env.profiles
        Task { await profiles.loadAvatarCatalog() }
    }

    override func sections() -> [UISettingsSection] {
        let profiles = env.profiles
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return [] }
        let header = env.wrap(ProfileEditHeader(profile: profile, notes: profiles.avatarName(for: profile),
                                                avatarSize: 100, topOnly: true)
            .frame(height: Self.previewHeight))
        if let preview { preview.set(header) } else {
            let view = UISettingsHosted(header)
            preview = view
            pin(view, height: Self.previewHeight)
        }
        // The initials on a colour, a group as the avatars' (picking one is
        // the initials on it), then every kind of avatar.
        let colours = ProfileStore.avatarColors.map { hex in
            UISettingsRow.Tile(id: "c." + hex, face: .colour(hex: hex, initial: profile.initial),
                               chosen: profile.avatarID == nil && profile.avatarColorHex.uppercased() == hex.uppercased()) {
                profiles.setColor(id: profile.id, hex: hex)
                profiles.setAvatar(id: profile.id, avatarID: nil)
            }
        }
        let kinds = AvatarChoices.groups(profiles.avatarCatalog).map { group in
            (name: group.name, tiles: group.items.map { item in
                UISettingsRow.Tile(id: "a." + item.id, face: .avatar(url: item.imageURL, name: item.displayName),
                                   chosen: profile.avatarID == item.id) {
                    profiles.setAvatar(id: profile.id, avatarID: item.id)
                }
            })
        }
        return [UISettingsSection(rows: [
            .tiles(.init(id: "pe.avatars", groups: [(name: "Colours", tiles: colours)] + kinds)),
        ])]
    }
}


/// For You: what Cue reads from your watching (the taste's columns, See
/// Everything), why Home's rows are there (See Everything, Rebuild Rows),
/// what's left out or rated (their pages).
private final class ForYouSettingsPage: UISettingsPage {
    override var title: String? { "For You" }
    private var saved: CueRows.Saved?
    private var loaded = false
    private var rebuild = CueRows.rebuildRequested

    override func appeared() {
        Task { [weak self] in
            self?.saved = await CueRows.saved()
            self?.loaded = true
            self?.changed()
        }
    }

    /// From Your Watching (Your Taste, Your Ratings, Dropped:
    /// their pages), Home's Rows (Rebuild on top, each row: why, its page).
    /// Nothing full screen.
    override func sections() -> [UISettingsSection] {
        guard let saved else {
            return loaded ? [UISettingsSection(rows: [.note("Not built yet. Open Home and Cue builds its rows.")])] : []
        }
        var sections: [UISettingsSection] = []
        // Your Taste its own page (with the rest below it, its columns
        // never fit with what's to press: a page only read can't scroll).
        var left: [UISettingsRow] = [
            .link(.init(id: "taste", title: "Your Taste", description: "What Cue has learned from what you watch and save.",
                        value: saved.taste.isEmpty ? nil : saved.titles == 1 ? "1 title" : "\(saved.titles) titles") { [weak self] in
                guard let self else { return }
                self.host.open(UIYourTastePage(host: self.host, saved: saved))
            }),
        ]
        let ratings = TitleRatings.shared.shown()
        let dropped = saved.droppedTitles?.count ?? saved.dropped?.count ?? 0
        if !ratings.isEmpty {
            left.append(.link(.init(id: "why.ratings", title: "Your Ratings",
                                    description: "Not for Me is never in Cue's rows; earlier Likes still count.",
                                    value: "\(ratings.count)") { [weak self] in
                guard let self else { return }
                self.host.open(UIWhyRatingsPage(host: self.host))
            }))
        }
        if dropped > 0 {
            left.append(.link(.init(id: "why.dropped", title: "Dropped",
                                    description: "Stopped early and left: out of Cue's rows, not counted in your taste.",
                                    value: "\(dropped)") { [weak self] in
                guard let self else { return }
                self.host.open(UIWhyDroppedPage(host: self.host, saved: saved))
            }))
        }
        sections.append(UISettingsSection(label: "From Your Watching", rows: left))
        // Last: it's long.
        let whys = saved.why.filter { $0.tab == "home" }
        let built = DateFormatter.settingsWhen.string(from: saved.builtAt)
        let header: UISettingsRow = .actions(.init(
            id: "why.rebuild", title: whys.count == 1 ? "1 Row" : "\(whys.count) Rows",
            detail: rebuild ? "New rows when Home opens" : "Built \(built) from \(saved.titles == 1 ? "1 title" : "\(saved.titles) titles") of yours.",
            actions: [rebuild
                ? Self.undoAction("rebuild", spelled: true) { [weak self] in
                    CueRows.rebuildRequested = false
                    self?.rebuild = false
                    self?.changed()
                }
                : SettingsAction(title: "Rebuild", icon: "arrow.clockwise", key: "rebuild", spelled: true) { [weak self] in
                    CueRows.rebuildRequested = true
                    self?.rebuild = true
                    self?.changed()
                }]))
        let how: UISettingsRow = .note("Each spot on Home keeps its kind of row; what's in it changes every day. "
            + "About two in three picks follow your taste, the rest come from outside it, so there's always something new.")
        sections.append(UISettingsSection(label: "Home's Rows", rows: [header, how] + whys.enumerated().map { index, why in
            .link(.init(id: "why.row.\(index)", title: why.title, description: why.reason) { [weak self] in
                guard let self else { return }
                let row = saved.rows.first { $0.title == why.title && ($0.tabs?.contains("home") ?? true) }
                self.host.open(UIWhyRowPage(host: self.host, why: why, row: row))
            })
        }))
        return sections
    }
}

/// Your Taste, only to read and on one screen: what it's read from, then
/// its columns (each kind's top six, a line each for languages, countries,
/// decades).
private final class UIYourTastePage: UISettingsPage {
    private let saved: CueRows.Saved

    init(host: CardSettingsController, saved: CueRows.Saved) {
        self.saved = saved
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { "Your Taste" }

    override func sections() -> [UISettingsSection] {
        guard !saved.taste.isEmpty else {
            return [UISettingsSection(rows: [.note("Nothing read yet. Watch something and Cue learns your taste.")])]
        }
        let saved = saved
        return [UISettingsSection(rows: [
            .info(title: saved.titles == 1 ? "From 1 title" : "From \(saved.titles) titles",
                  value: "Watched, started or saved; newer ones count more"),
            .hosted(.init(id: "taste.grid", key: "\(saved.builtAt.timeIntervalSince1970)", readOnly: true) {
                AnyView(WhyTasteGrid(saved: saved))
            }),
        ])]
    }
}

/// A row of Home's, why it's there: how many titles and the reason on top
/// (what else went into it under that), then its titles, each with why
/// it's in the row, Open.
private final class UIWhyRowPage: UISettingsPage {
    private let why: CueRows.Why
    private let row: CueRows.Row?

    init(host: CardSettingsController, why: CueRows.Why, row: CueRows.Row?) {
        self.why = why
        self.row = row
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { why.title }

    override func sections() -> [UISettingsSection] {
        let items = row?.items ?? []
        var rows: [UISettingsRow] = [.actions(.init(
            id: "row.top", title: items.count == 1 ? "1 Title" : "\(items.count) Titles", detail: why.reason, actions: []))]
        if let notes = why.notes, !notes.isEmpty { rows.append(.note(notes.joined(separator: " "))) }
        let open = env.openTitle
        let ranked = row?.shape == .ranked
        rows += items.enumerated().map { index, item in
            .actions(.init(
                id: "row.\(item.id)", leading: .poster(item.poster),
                title: ranked ? "\(index + 1). \(item.name)" : item.name,
                detail: row?.whys?[item.id] ?? "",
                actions: open == nil ? [] : [SettingsAction(title: "Open", icon: "info.circle", key: "open") { open?(item) }]))
        }
        return [UISettingsSection(rows: rows)]
    }
}

/// Your ratings by rating, newest first: Open, Remove (undone in place,
/// gone as the page goes).
private final class UIWhyRatingsPage: UISettingsPage {
    /// What a rating does, under its count.
    private static func ratingDetail(_ rating: TitleRatings.Rating) -> String {
        switch rating {
        case .love: "Count twice in your taste, and seed Because You Watched."
        case .like: "Count one and a half times in your taste."
        case .notForMe: "Never in Cue's rows or the billboard."
        case .starter: ""
        }
    }

    private let ratings = TitleRatings.shared.shown()
    private var pending: Set<String> = [] { didSet { changed() } }

    override var title: String? { "Your Ratings" }

    override func disappeared() {
        if !pending.isEmpty { TitleRatings.shared.clear(Array(pending)) }
        pending = []
    }

    override func sections() -> [UISettingsSection] {
        let open = env.openTitle
        return TitleRatings.Rating.allCases.reversed().compactMap { rating in
            let entries = ratings.filter { $0.value.rating == rating }.sorted { $0.value.at > $1.value.at }
            guard !entries.isEmpty else { return nil }
            let keys = entries.map(\.key)
            let leftCount = keys.filter { !pending.contains($0) }.count
            let all = leftCount == 0
            let header: UISettingsRow = .actions(.init(
                id: "why.rating.all.\(rating.rawValue)", title: leftCount == 1 ? "1 Title" : "\(leftCount) Titles",
                detail: Self.ratingDetail(rating), actions: [all
                    ? Self.undoAction("all", spelled: true, title: "Undo All") { [weak self] in self?.pending.subtract(keys) }
                    : SettingsAction(title: "Remove All", icon: "trash", danger: true, key: "all", spelled: true) { [weak self] in
                        self?.pending.formUnion(keys)
                    }]))
            return UISettingsSection(label: rating.name, rows: [header] + entries.map { id, entry in
                let gone = pending.contains(id)
                return .actions(.init(
                    id: "why.rating.\(id)", title: entry.name,
                    detail: gone ? "Removed" : "Rated " + DateFormatter.settingsWhen.string(from: entry.at),
                    dimmed: gone,
                    actions: [
                        SettingsAction(title: "Open", icon: "info.circle", key: "open") {
                            open?(MetaItem(id: id, type: entry.type, name: entry.name))
                        },
                        gone
                            ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { [weak self] in self?.pending.remove(id) }
                            : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { [weak self] in self?.pending.insert(id) },
                    ]))
            })
        }
    }
}

/// Dropped: each with how far you got; Open (watching on is what changes it).
private final class UIWhyDroppedPage: UISettingsPage {
    private let saved: CueRows.Saved

    init(host: CardSettingsController, saved: CueRows.Saved) {
        self.saved = saved
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String? { "Dropped" }

    override func sections() -> [UISettingsSection] {
        guard let titles = saved.droppedTitles else {
            return [UISettingsSection(rows: [.note("Rebuild Rows to see these titles here.")])]
        }
        let open = env.openTitle
        let header: UISettingsRow = .actions(.init(
            id: "why.dropped.all", title: "\(titles.count) Dropped",
            detail: "Stopped early and left: out of Cue's rows until you watch on.", actions: []))
        return [UISettingsSection(rows: [header] + titles.map { title in
            .actions(.init(id: "why.dropped.\(title.id)", title: title.name, detail: title.note ?? "",
                           actions: [SettingsAction(title: "Open", icon: "info.circle", key: "open") {
                               open?(MetaItem(id: title.id, type: title.type, name: title.name))
                           }]))
        })]
    }
}

/// Whether a page's first section has a label (Settings 2's columns line
/// up by it).
struct CardFirstLabelKey: PreferenceKey {
    static let defaultValue: Bool? = nil
    static func reduce(value: inout Bool?, nextValue: () -> Bool?) {
        if value == nil { value = nextValue() }
    }
}

// MARK: - Pieces the SwiftUI pages still draw

/// One section of Settings 2: its label, then its rows on one card, a
/// hairline between two rows unless one of them has focus or is selected.
/// Whether a page's first section has a label (Settings 2's columns
/// line up by it).
struct CardSettingsSection: View {
    /// A label's room above its card.
    static let labelRoom: CGFloat = 42
    var label: String? = nil
    /// Below the card, to the next section.
    var gap: CGFloat = 40
    let rows: [CardSettingsRow]
    var focused: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                Text(label)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(CueInk.tertiary)
                    .padding(.leading, CardSettingsRow.textInset)
                    .frame(height: Self.labelRoom - 12, alignment: .top)
                    .padding(.bottom, 12)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        let quiet = [row, rows[index - 1]].contains { focused.wrappedValue == $0.id || $0.selected }
                        Rectangle()
                            .fill(CueInk.color(0.10))
                            .frame(height: 1)
                            .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
                            .padding(.vertical, 5)
                            .opacity(quiet ? 0 : 1)
                    }
                    row.focused(focused, equals: row.id)
                }
            }
            .padding(CardSettingsRow.cardPadding)
            .background(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
                .fill(CardFocusPlate.cardFill))
        }
        .padding(.bottom, gap)
        .preference(key: CardFirstLabelKey.self, value: label != nil)
    }
}

/// white plate, dark words.
struct CardSettingsRow: View {
    let id: String
    let title: String
    var description: String? = nil
    var value: String? = nil
    var chevron = false
    /// The category shown beside it (focus in its settings): the selected grey.
    var selected = false
    var reachable = true
    /// Shorter (the categories: all in view).
    var compact = false
    let action: () -> Void

    /// A focus plate from the card's edge: its corners concentric with the
    /// card's (22 − 6 = 16).
    static let plateInset: CGFloat = 6
    /// A plate past its row, above and below: half the gap between two
    /// rows, so it covers the hairlines beside it.
    static let plateBleed: CGFloat = 6
    /// A card's padding round its rows: the plates' inset, and room for a
    /// first or last plate's bleed.
    static var cardPadding: EdgeInsets {
        EdgeInsets(top: plateInset + plateBleed, leading: plateInset,
                   bottom: plateInset + plateBleed, trailing: plateInset)
    }
    /// The words from the card's edge (Upcoming's).
    static let textInset: CGFloat = 24

    var body: some View {
        Button(action: action) { CardSettingsRowFace(row: self) }
            .buttonStyle(CardSettingsRowStyle())
            .disabled(!reachable)
    }
}

private struct CardSettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct CardSettingsRowFace: View {
    @Environment(\.isFocused) private var isFocused
    let row: CardSettingsRow

    var body: some View {
        let ink = isFocused ? Color.black : CueInk.primary
        let quiet = isFocused ? Color.black.opacity(0.6) : CueInk.body
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(row.title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ink)
                Spacer(minLength: 24)
                if let value = row.value {
                    Text(value)
                        .font(.system(size: 24))
                        .foregroundStyle(quiet)
                }
                if row.chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(quiet)
                }
            }
            if let description = row.description {
                Text(description)
                    .font(.system(size: 24))
                    .foregroundStyle(quiet)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
        .padding(.vertical, row.compact ? 9 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardFocusPlate(lit: isFocused, selected: row.selected) }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}


@MainActor
final class CacheMeter: ObservableObject {
    static let shared = CacheMeter()
    @Published private(set) var parts: [CacheStorage.Part]?
    @Published private(set) var free: Int64?
    @Published private(set) var clearing = false

    func measure() async {
        parts = await CacheStorage.measure()
        free = CacheStorage.available()
    }

    func clear() {
        guard !clearing else { return }
        clearing = true
        Task {
            await CacheStorage.clear()
            await measure()
            clearing = false
        }
    }

    func summary(_ tail: String) -> String {
        if clearing { return "Clearing…" }
        guard let parts else { return "Measuring…" }
        return CachePage.size(parts.reduce(0) { $0 + $1.bytes }) + tail
    }
}

