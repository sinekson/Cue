import SwiftUI

/// A card in a destination row, as the controller sees it: its row and
/// its place in it.
protocol FixedFocusDestinationItem: UIView {
    var itemIndex: Int { get }
    var rowCell: FixedFocusRowCell? { get }
}

/// A banner row's card — Search's Top Result — drawn as a small billboard:
/// the backdrop filling it, the billboard's left fade, and over it the
/// billboard's text as Home's billboard has it — the logo (or the name), the
/// chips, the facts and the tagline — at its sizes, only the logo shorter.
/// Focused: Cue's outline and a shadow.
final class FixedFocusBannerCell: UICollectionViewCell, FixedFocusDestinationItem {
    private(set) var itemIndex = 0
    private(set) weak var rowCell: FixedFocusRowCell?
    private let card = UIView()
    private let backdrop = UIImageView()
    private let fade = CAGradientLayer()
    private let logo = LeftAlignedImageView()
    /// The title in big type, where there's no logo.
    private let name = UILabel()
    private let facts = UILabel()
    /// The tagline (TMDB) — no tagline: the name, so the block keeps its
    /// height.
    private let tagline = UILabel()
    /// The chips line (status, the first three ratings) — the billboard's
    /// own SwiftUI chips, hosted.
    private let chips = UIHostingController(rootView: AnyView(EmptyView()))
    /// Loads the facts' season count and the tagline for the shown title.
    private var extras: Task<Void, Never>?
    private let outline = UIView()
    private let shadow = UIImageView()
    /// The cards' edge, as on every card.
    private let edge = UIImageView()
    private var item: MetaItem?
    private var focusedNow = false

    /// The text column: from the card's left, this wide.
    private static let textInset: CGFloat = 56
    private static let textWidth: CGFloat = 760
    /// No picture at all.
    private static let empty = UIColor(white: 0.12, alpha: 1)
    /// The picture on its way: the placeholder's look.
    private let loadingCard = FixedFocusPlaceholder()
    private static let logoHeight: CGFloat = 96

    override init(frame: CGRect) {
        super.init(frame: frame)
        FixedFocusRing.follow(self)
        shadow.image = FixedFocusCardEdge.shadowImage
        shadow.alpha = 0
        contentView.addSubview(shadow)
        card.clipsToBounds = true
        card.layer.cornerRadius = Spotlight.cornerRadius
        card.layer.cornerCurve = .continuous
        card.backgroundColor = Self.empty
        contentView.addSubview(card)
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        card.addSubview(backdrop)
        loadingCard.isHidden = true
        loadingCard.layer.cornerRadius = 0
        card.addSubview(loadingCard)
        // The billboard's left fade: dark under the text, gone by mid-card.
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [0.92, 0.85, 0.55, 0].map { UIColor.black.withAlphaComponent($0).cgColor }
        fade.locations = [0, 0.3, 0.5, 0.75]
        card.layer.addSublayer(fade)
        name.font = .systemFont(ofSize: 52, weight: .bold)
        name.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        name.numberOfLines = 2
        // As on the billboard: the facts bright, the tagline quiet and italic.
        facts.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .medium)
        facts.textColor = UIColor.white.withAlphaComponent(FixedFocusText.body)
        tagline.font = UIFont(descriptor: UIFont.systemFont(ofSize: FixedFocusMetrics.textSize)
            .fontDescriptor.withSymbolicTraits(.traitItalic) ?? UIFont.systemFont(ofSize: FixedFocusMetrics.textSize).fontDescriptor,
                              size: FixedFocusMetrics.textSize)
        tagline.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        chips.view.backgroundColor = .clear
        chips.safeAreaRegions = []
        for view: UIView in [logo, name, chips.view, facts, tagline] { card.addSubview(view) }
        edge.isUserInteractionEnabled = false
        card.addSubview(edge)
        // A logo arriving replaces the name: the column is laid out again.
        logo.imageView.onImage = { [weak self] in self?.setNeedsLayout() }
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outline.layer.borderWidth = FixedFocusRing.width
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.alpha = 0
        contentView.addSubview(outline)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Outside a row (Search's grid): the app's stores for its chips.
    var environment: (AnyView) -> AnyView = { $0 }

    func configure(_ item: MetaItem, index: Int, rowCell: FixedFocusRowCell?) {
        itemIndex = index
        self.rowCell = rowCell
        if self.item?.id != item.id {
            FixedFocusImages.load(item.background ?? item.poster, into: backdrop,
                                  maxDimension: PictureSize.landscape,
                                  waiting: { [weak self] waiting in
                guard let self else { return }
                self.loadingCard.follow(waiting: waiting)
                self.card.backgroundColor = waiting ? nil : Self.empty
                self.edge.isHidden = waiting
            })
            logo.image = nil
            FixedFocusImages.load(item.logo, into: logo.imageView, maxDimension: PictureSize.cardLogo)
        }
        let changed = self.item?.id != item.id
        self.item = item
        name.text = item.name
        chips.rootView = rowCell?.hosted(TitleChipsLine(item: item)) ?? environment(AnyView(TitleChipsLine(item: item)))
        if changed {
            facts.text = FixedFocusShowInfo.factsLine(item)
            tagline.text = TitleRecords.shared.tagline(item) ?? item.name
            extras?.cancel()
            extras = Task { @MainActor [weak self] in
                guard await TitleRecords.shared.refresh(item, [.show, .facts]),
                      let self, !Task.isCancelled, self.item?.id == item.id else { return }
                self.facts.text = FixedFocusShowInfo.factsLine(item)
                self.tagline.text = TitleRecords.shared.tagline(item) ?? item.name
            }
        }
        applyFocus(isFocused)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre: they may be grown (transformed).
        for view in [card, outline] {
            view.bounds = CGRect(origin: .zero, size: bounds.size)
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        outline.layer.borderWidth = FixedFocusRing.width
        shadow.bounds = CGRect(origin: .zero, size: bounds.insetBy(dx: -FixedFocusCardEdge.shadowPad,
                                                                    dy: -FixedFocusCardEdge.shadowPad).size)
        shadow.center = CGPoint(x: bounds.midX, y: bounds.midY)
        edge.image = FixedFocusCardEdge.rim
        edge.frame = card.bounds
        loadingCard.frame = card.bounds
        // A WINDOW onto the full-screen picture: the backdrop at the size and
        // place Details (and Home's billboard) give it, seen through the
        // card — the very same picture.
        let origin = rowCell.map { $0.restingCardOrigin() ?? .zero } ?? convert(CGPoint.zero, to: nil)
        let drift = StagePictureView.drift
        backdrop.frame = CGRect(x: -drift - origin.x, y: -origin.y,
                                width: StagePictureView.pictureSize.width + 2 * drift,
                                height: StagePictureView.pictureSize.height)
        fade.frame = card.bounds
        // The text column, centred on the card's height, in the billboard's
        // order and rhythm: the logo (or the name), the chips, the facts,
        // the tagline.
        let x = Self.textInset, width = Self.textWidth
        let hasLogo = logo.image != nil
        name.isHidden = hasLogo
        logo.isHidden = !hasLogo
        let titleHeight = hasLogo ? Self.logoHeight
            : name.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let line = FixedFocusMetrics.factsHeight
        let gap = FixedFocusMetrics.factsOffset - 30   // the billboard's line step
        let chipsGap = gap + FixedFocusBillboardText.chipsGap
        let total = titleHeight + FixedFocusBillboardText.logoToChips + line + chipsGap + line + gap + 30
        var y = max(24, (bounds.height - total) / 2)
        logo.frame = CGRect(x: x, y: y, width: width * 0.7, height: Self.logoHeight)
        name.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + FixedFocusBillboardText.logoToChips
        chips.view.frame = CGRect(x: x, y: y, width: width, height: line)
        y += line + chipsGap
        facts.frame = CGRect(x: x, y: y, width: width, height: line)
        y += line + gap
        tagline.frame = CGRect(x: x, y: y, width: width, height: 30)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            self.applyFocus(focused)
        } completion: { _ in }
    }

    /// (No lift: the window stays exactly where the picture is.)
    private func applyFocus(_ focused: Bool) {
        focusedNow = focused
        outline.alpha = focused ? 1 : 0
        shadow.alpha = focused ? 1 : 0
    }
}

/// The chips line on its own — the status badge (optional), then the first
/// ratings — loading the ratings itself: the Top Result's banner, and the
/// window opening from it into Details.
struct TitleChipsLine: View {
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    let item: MetaItem
    var includesStatus = true
    /// Bumped when its record changes (`TitleRecords`).
    @State private var record = 0

    var body: some View {
        let _ = record
        HStack(spacing: 10) {
            if includesStatus, let status = FixedFocusShowInfo.status(item) {
                TitleBadge(text: status)
            }
            FixedFocusBillboardText.ratingsChips(TitleRecords.shared.ratings(item) ?? nil,
                                                 settings: mdblist.settings, item: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: item.id) {
            if await TitleRecords.shared.refresh(item, [.show, .facts, .ratings]) { record += 1 }
        }
    }
}

/// Holding Select on a Continue Watching card: the system's context menu
/// (lifting the card, blurring the rest, in Liquid Glass), with these.
enum ContinueMenuAction: CaseIterable {
    case details, startOver, chooseSource, markWatched, remove

    /// `series`: the card is an episode, so Details is the show's.
    func title(series: Bool) -> String {
        switch self {
        case .details: return series ? "Go to Show" : "Go to Movie"
        case .startOver: return "Start Over"
        case .chooseSource: return "Choose Source"
        case .markWatched: return "Mark as Watched"
        case .remove: return "Remove from Continue Watching"
        }
    }

    var icon: String {
        switch self {
        case .details: return "info.circle"
        case .startOver: return "gobackward"
        case .chooseSource: return "list.and.film"
        case .markWatched: return "checkmark.circle"
        case .remove: return "minus.circle"
        }
    }
}

private extension View {
    /// Into a rect of the screen (top-left origin).
    func place(_ rect: CGRect, alignment: Alignment = .center) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment)
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// An image view that draws its picture aspect-fit to its LEFT edge (a
/// logo in a text column), not centred. Load into `imageView`.
final class LeftAlignedImageView: UIView {
    /// Tells its holder whenever a picture arrives (`onImage`).
    final class Picture: UIImageView {
        var onImage: () -> Void = {}
        override var image: UIImage? {
            didSet { superview?.setNeedsLayout(); onImage() }
        }
    }
    let imageView = Picture()
    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
            imageView.frame = .zero
            return
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        // Left, and down to the bottom (it sits on the facts line).
        imageView.frame = CGRect(x: 0, y: bounds.height - fitted.height, width: fitted.width, height: fitted.height)
    }
}

/// A destination row's card: its picture with Cue's focus outline (or
/// tvOS's lift — `FixedFocusMetrics.destinationSystemLift`); under it the
/// name and a second line (when it was saved, how many catalogs).
final class FixedFocusDestinationCell: UICollectionViewCell, FixedFocusDestinationItem {
    private(set) var itemIndex = 0
    private(set) weak var rowCell: FixedFocusRowCell?
    private let picture = UIImageView()
    /// The card's edge and the focus outline, as on
    /// the other rows' cards.
    private let edge = UIImageView()
    private let outline = UIView()
    private let outlineLight = UIImageView()
    /// The lift's scale the outline is sized to (see `setFocused`).
    private var outlineScale: CGFloat = 1
    private let name = UILabel()
    private let detail = UILabel()
    /// A logo row's logo: fitted inside the picture's light plate.
    private let logo = UIImageView()
    static let logoInset = CGSize(width: 34, height: 30)

    /// Darkened (0…1 black over the picture — not see-through).
    var dim: CGFloat = 0 {
        didSet { if dim != oldValue { dimCover.alpha = dim; spine.alpha = 1 - dim } }
    }
    private let dimCover = UIView()
    /// A ranked row's place (Top 10): a short card behind the poster,
    /// `rankInset` under its top, showing `rankLead` of it at its left, in
    /// the tertiary white, lifted with the poster, the digit cut out of it.
    /// (Stretched tall was tried.) (A numeral over the poster, Netflix's numeral behind
    /// it, a strip joined to the poster with the word turned, the word
    /// written downwards, alone or with the digit, were tried.)
    private let spine = UIImageView()
    private var lead: CGFloat = 0
    /// The caption starts under the poster, not the card behind it.
    private var captionLeading: NSLayoutConstraint!
    static let rankLead: CGFloat = 56
    /// How far the card behind runs under the poster.
    static let rankUnder: CGFloat = 60
    /// Its distance from the poster's top, and its height.
    static let rankInset: CGFloat = 48
    static let rankHeight: CGFloat = 90
    private static var spines: [Int: UIImage] = [:]
    static func spineImage(_ place: Int) -> UIImage {
        if let image = spines[place] { return image }
        let size = CGSize(width: rankLead + rankUnder, height: rankHeight)
        let font = UIFont.systemFont(ofSize: 40, weight: .bold)
        let digit = NSAttributedString(string: "\(place)", attributes: [.font: font])
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            UIColor.white.withAlphaComponent(FixedFocusText.tertiary).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setBlendMode(.clear)
            // Centred on its capitals.
            digit.draw(at: CGPoint(x: (rankLead - digit.size().width) / 2,
                                   y: size.height / 2 - font.ascender + font.capHeight / 2))
        }
        spines[place] = image
        return image
    }
    private var place = 0
    /// Grown about the poster's centre, not its own.
    private func grow(_ view: UIView, _ scale: CGFloat) {
        let unit = cardFrame
        let dx = (view.center.x - unit.midX) * (scale - 1)
        let dy = (view.center.y - unit.midY) * (scale - 1)
        view.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    /// The name and second line under the card (its row focused).
    func setCaptionShown(_ shown: Bool) {
        name.alpha = shown ? 1 : 0
        detail.alpha = shown ? 1 : 0
        nameBar.alpha = name.alpha
        detailBar.alpha = detail.alpha
    }

    /// Continue Watching's state (episode, progress, time left), if it is one,
    /// over the picture's lower half darkened (as the fixed-focus card).
    private let state = FixedFocusProgressView()
    private let stateShade = CAGradientLayer()
    /// The captions' gap below the card (larger while it's grown).
    private var captionGap: NSLayoutConstraint!
    private var cardHeight: CGFloat = 0
    private var shown: String?
    private static var lift: Bool { FixedFocusMetrics.destinationSystemLift }
    /// Still loading: the placeholder card.
    private let placeholderCard = FixedFocusPlaceholder()
    /// Its caption's two lines still to come, as bars (as tall as the
    /// text's capitals).
    private let nameBar = FixedFocusPlaceholder()
    private let detailBar = FixedFocusPlaceholder()
    private var isPlaceholder = false
    /// Its picture on its way: the placeholder's look over the empty card.
    private let loadingCard = FixedFocusPlaceholder()

    override init(frame: CGRect) {
        super.init(frame: frame)
        FixedFocusRing.follow(self)
        picture.adjustsImageWhenAncestorFocused = Self.lift
        picture.contentMode = .scaleAspectFill
        if !Self.lift {
            picture.clipsToBounds = true
            picture.layer.cornerRadius = Spotlight.cornerRadius
            picture.layer.cornerCurve = .continuous
        }
        spine.isHidden = true
        spine.layer.cornerRadius = Spotlight.cornerRadius
        spine.layer.cornerCurve = .continuous
        spine.clipsToBounds = true
        contentView.addSubview(spine)
        contentView.addSubview(picture)
        placeholderCard.isHidden = true
        contentView.addSubview(placeholderCard)
        loadingCard.isHidden = true
        picture.addSubview(loadingCard)
        edge.isUserInteractionEnabled = false
        picture.addSubview(edge)
        stateShade.colors = [UIColor.clear.cgColor,
                             UIColor.black.withAlphaComponent(Spotlight.logoScrimOpacity).cgColor]
        stateShade.startPoint = CGPoint(x: 0.5, y: 0.5)
        stateShade.endPoint = CGPoint(x: 0.5, y: 1)
        stateShade.isHidden = true
        picture.layer.insertSublayer(stateShade, at: 0)
        state.alpha = 0
        state.isUserInteractionEnabled = false
        picture.addSubview(state)
        logo.contentMode = .scaleAspectFit
        logo.isHidden = true
        picture.addSubview(logo)
        dimCover.backgroundColor = .black
        dimCover.alpha = 0
        dimCover.isUserInteractionEnabled = false
        picture.addSubview(dimCover)
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = UIColor.white.cgColor
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.addSubview(outlineLight)
        outline.alpha = 0
        contentView.addSubview(outline)
        FixedFocusRing.attachShadow(to: outline)
        // Like the fixed box's text (see its `InfoPage`), a little smaller
        // (`FixedFocusText.titleFont`, `infoFont`).
        name.font = FixedFocusText.titleFont(FixedFocusMetrics.captionSize)
        name.lineBreakMode = .byTruncatingTail
        detail.font = FixedFocusText.infoFont(FixedFocusMetrics.captionSize)
        detail.textColor = UIColor.white.withAlphaComponent(FixedFocusText.infoLevel(focused: false))
        for label in [name, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
        }
        // Below the picture's FOCUSED frame: a lift pushes them down.
        captionGap = name.topAnchor.constraint(equalTo: picture.focusedFrameGuide.bottomAnchor,
                                               constant: FixedFocusMetrics.infoGap)
        captionLeading = name.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,
                                                       constant: FixedFocusMetrics.textIndent)
        NSLayoutConstraint.activate([
            captionGap,
            captionLeading,
            name.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FixedFocusMetrics.textIndent),
            name.heightAnchor.constraint(equalToConstant: 30),
            detail.topAnchor.constraint(equalTo: name.topAnchor, constant: FixedFocusMetrics.captionLineOffset),
            detail.heightAnchor.constraint(equalToConstant: FixedFocusMetrics.factsHeight),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
        ])
        let barHeight = (FixedFocusMetrics.captionSize * 0.72).rounded()
        for (bar, label, share) in [(nameBar, name, 0.7), (detailBar, detail, 0.3)] {
            bar.isHidden = true
            bar.layer.cornerRadius = barHeight / 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                bar.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                bar.heightAnchor.constraint(equalToConstant: barHeight),
                bar.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: share),
            ])
        }
        applyFocus(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre, not frames: they may be grown (transformed).
        let card = cardFrame
        picture.bounds = CGRect(origin: .zero, size: card.size)
        picture.center = CGPoint(x: card.midX, y: card.midY)
        outline.center = picture.center
        outline.bounds = CGRect(origin: .zero, size: CGSize(width: card.width * outlineScale,
                                                            height: card.height * outlineScale))
        if !spine.isHidden {
            let top = Self.spineImage(place)
            spine.image = top
            spine.bounds = CGRect(origin: .zero, size: top.size)
            let x = top.size.width / 2
            spine.center = CGPoint(x: x, y: Self.rankInset + top.size.height / 2)
            grow(spine, outlineScale)
        }
        edge.image = Self.lift ? nil : FixedFocusCardEdge.rim
        edge.frame = picture.bounds
        loadingCard.frame = picture.bounds
        placeholderCard.frame = card
        placeholderCard.isHidden = !isPlaceholder
        nameBar.isHidden = !isPlaceholder
        detailBar.isHidden = !isPlaceholder
        picture.isHidden = isPlaceholder
        dimCover.frame = picture.bounds
        logo.frame = picture.bounds.insetBy(dx: Self.logoInset.width, dy: Self.logoInset.height)
        // (As on Continue Watching's fixed-focus cards.)
        state.frame = card
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stateShade.frame = picture.bounds
        CATransaction.commit()
        let lit = FixedFocusCardEdge.focusLight
        outline.layer.borderWidth = lit ? 0 : FixedFocusRing.width
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outlineLight.image = lit ? FixedFocusCardEdge.focusImage : nil
        outlineLight.frame = outline.bounds
    }

    /// The card itself, without its caption (in the cell).
    var cardFrame: CGRect { CGRect(x: lead, y: 0, width: bounds.width - lead, height: cardHeight) }

    /// Its hold menu (`HoldMenu`): beside the card at its held size —
    /// lifted and a little grown — without its caption.
    func holdMenu(_ entries: [MenuEntry]) -> HoldMenuRequest {
        let lift = FixedFocusMetrics.movingFocusLift
        let scale = lift > 0 && !Self.lift ? 1 + lift + FixedFocusMetrics.heldGrowth : 1
        let card = cardFrame
        func sized(_ scale: CGFloat) -> CGRect {
            convert(card.insetBy(dx: -card.width * (scale - 1) / 2, dy: -card.height * (scale - 1) / 2), to: nil)
        }
        let now = scale == 1 ? 1 : 1 + lift - (pressed ? 1 - FixedFocusMetrics.pressScale : 0)
        return HoldMenuRequest(entries: entries, anchor: sized(scale), from: sized(now),
                               rest: sized(scale == 1 ? 1 : 1 + lift),
                               onHeld: { [weak self] in self?.setHeld($0) })
    }

    /// New progress for the title it already shows.
    func showProgress(_ progress: WatchProgress) {
        detail.text = progress.episodeTitle ?? detail.text
        state.show(progress)
    }

    func configure(_ item: MetaItem, subtitle: String?, index: Int, rowCell: FixedFocusRowCell?, card: CGSize,
                   progress: WatchProgress? = nil, cardState: FixedFocusCardState? = nil, isLogo: Bool = false,
                   rank place: Int? = nil, lead: CGFloat = 0) {
        itemIndex = index
        self.rowCell = rowCell
        cardHeight = card.height
        self.lead = lead
        spine.isHidden = place == nil
        captionLeading.constant = FixedFocusMetrics.textIndent + lead
        if let place { self.place = place }
        isPlaceholder = FixedFocusPlaceholder.isPlaceholder(item)
        setNeedsLayout()
        // (A reused cell: its last focus look gone.)
        applyFocus(isFocused)
        name.text = item.name
        // Continue Watching (moving focus): the episode's title under it, and
        // the episode, bar and time left on the darkened picture.
        detail.text = progress?.episodeTitle ?? subtitle
        // (Or a state line given as such — Details' episodes.)
        if let cardState { state.show(cardState) } else { state.show(progress) }
        let hasState = progress != nil || cardState != nil
        state.alpha = hasState ? 1 : 0
        stateShade.isHidden = !hasState
        setNeedsLayout()
        let art = card.width > card.height ? (item.background ?? item.poster) : (item.poster ?? item.background)
        let blurred = cardState?.blurred == true
        let key = "\(item.id)|\(art ?? "")|\(Int(card.width))|\(blurred)"
        guard key != shown else { return }
        shown = key
        // A logo: on a light plate, fitted with room around it.
        logo.isHidden = !isLogo
        if isLogo {
            // (Drops a reused card's poster still on its way — it landed
            // over the logo's plate.)
            FixedFocusImages.load(nil, into: picture, maxDimension: 0)
            logo.image = nil
            FixedFocusImages.load(art, into: logo, maxDimension: PictureSize.landscape,
                                  waiting: { [weak self] in self?.pictureWaiting($0, plate: true) })
            return
        }
        guard let art else {
            // No picture: the title's name — a person's initials.
            let text = item.type == "person"
                ? item.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
                : item.name
            FixedFocusImages.load(nil, into: picture, maxDimension: 0)
            picture.image = TileArt.placeholder(size: card, text: text)
            pictureWaiting(false, plate: false)
            return
        }
        if blurred {
            // Blurred once into a still (`BlurredBackdrop`); a plain load
            // still on its way is dropped.
            FixedFocusImages.load(nil, into: picture, maxDimension: 0)
            if let ready = BlurredBackdrop.cached(for: art) {
                picture.image = ready
                pictureWaiting(false, plate: false)
                return
            }
            pictureWaiting(true, plate: false)
            Task { [weak self] in
                let image = await BlurredBackdrop.image(for: art)
                guard let self, self.shown == key else { return }
                self.picture.image = image
                self.pictureWaiting(false, plate: false)
            }
        } else if Self.lift {
            // The system's effect needs the corners in the picture itself.
            picture.image = nil
            pictureWaiting(true, plate: false)
            TileArt.load(art, size: card, contain: false) { [weak self] image in
                guard let self, self.shown == key, let image else { return }
                self.picture.image = image
                self.pictureWaiting(false, plate: false)
            }
        } else {
            FixedFocusImages.load(art, into: picture, maxDimension: card.width > card.height ? PictureSize.landscape : PictureSize.poster,
                                  waiting: { [weak self] in self?.pictureWaiting($0, plate: false) })
        }
    }

        /// The picture (or a logo's plate) waits under the placeholder's look:
    /// no edge, no plate until it's in.
    private func pictureWaiting(_ waiting: Bool, plate: Bool) {
        loadingCard.follow(waiting: waiting)
        edge.isHidden = waiting
        picture.backgroundColor = plate && !waiting ? UIColor(white: 0.9, alpha: 1) : nil
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        // Focus into a hold menu (`HoldMenu`): the card stays lifted.
        let focused = isFocused || (HoldMenu.shared.isOpen && context.previouslyFocusedView === self)
        guard !Self.lift else {
            coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
            return
        }
        // On Home's curve and timing, with the row's scroll.
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            self.applyFocus(focused)
            self.layoutIfNeeded()
        } completion: { _ in }
    }

    /// Select pressed / held: the card sinks a little (back on release, or
    /// when the menu closes).
    private var pressed = false
    private var focusedNow = false
    /// Its hold menu open: a little larger than lifted.
    private var held = false
    func setHeld(_ held: Bool) {
        guard held != self.held else { return }
        self.held = held
        UIView.animate(withDuration: FixedFocusMetrics.heldDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.applyFocus(self.focusedNow)
        }
    }
    func setPressed(_ pressed: Bool) {
        guard pressed != self.pressed else { return }
        self.pressed = pressed
        UIView.animate(withDuration: pressed ? 0.12 : 0.2, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.applyFocus(self.focusedNow)
        }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(true) }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(false) }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(false) }
        super.pressesCancelled(presses, with: event)
    }

    private func applyFocus(_ focused: Bool) {
        focusedNow = focused
        // Out of focus one level down: the name secondary, the line tertiary.
        name.textColor = UIColor.white.withAlphaComponent(FixedFocusText.titleLevel(focused: focused))
        detail.textColor = UIColor.white.withAlphaComponent(FixedFocusText.infoLevel(focused: focused))
        guard !Self.lift else { return }
        // Grown and outlined — the captions step down with it.
        let lift = FixedFocusMetrics.movingFocusLift
        let grows = lift > 0
        // Pressed: a little less lifted (as the fixed box sinks, `pressScale`).
        let scale = focused && grows
            ? 1 + lift - (pressed ? 1 - FixedFocusMetrics.pressScale : 0) + (held ? FixedFocusMetrics.heldGrowth : 0)
            : 1
        let grown = CGAffineTransform(scaleX: scale, y: scale)
        picture.transform = grown
        if !spine.isHidden { grow(spine, scale) }
        // The outline SIZED with the card, not scaled: its line stays the
        // fixed box's width (scaled, it grew thicker with the lift).
        outlineScale = scale
        outline.bounds = CGRect(origin: .zero, size: CGSize(width: cardFrame.width * scale, height: cardHeight * scale))
        outline.layer.cornerRadius = Spotlight.cornerRadius * scale
        outline.alpha = focused ? 1 : 0
        // The caption keeps its distance to the card at its FOCUSED size:
        // pressing or holding (brief, the card's own feedback) doesn't move it.
        let focusedScale = focused && grows ? 1 + lift : 1
        captionGap.constant = FixedFocusMetrics.infoGap + cardHeight * (focusedScale - 1) / 2
        if focused { superview?.bringSubviewToFront(self) }
    }

}

/// A poster cell: a WINDOW onto two fixed-size images — the portrait
/// poster and the box-sized backdrop (with logo). Growing opens the window;
/// nothing is stretched. Backdrop and logo load only once it grows.
/// A move of the rows, as the cards laid out in it see it (read through
/// their row while `FixedFocusMotion.run`'s animation block runs).
struct FixedFocusMove {
    /// An Up/Down movement: its direction and duration.
    var vertical: (direction: CGFloat, duration: Double)?
    /// A move that changes a card between poster and box (Up/Down, and
    /// Left/Right while an opening still runs — the cells carry it): its
    /// duration.
    var reshaping: Double?
}

final class FixedFocusPosterCell: UICollectionViewCell {

    // Select pressed / held: the box (which shows this card) sinks a little.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { rowCell?.setBoxPressed(true) }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { rowCell?.setBoxPressed(false) }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { rowCell?.setBoxPressed(false) }
        super.pressesCancelled(presses, with: event)
    }

    private(set) var itemIndex = 0
    private(set) weak var rowCell: FixedFocusRowCell?
    private let poster = UIImageView()
    private let backdrop = UIImageView()
    private let shade = FixedFocusShade()
    private let logo = FixedFocusLogo()
    /// The grown cell's own outline — fades in as it opens (Up/Down), while
    /// the fixed box is away.
    private let outline = UIView()
    /// The title's info (name, facts) — BELOW the cell, so it travels with
    /// its title: in with it, away with it.
    private let info = UIView()
    private let name = UILabel()
    private let facts = UILabel()
    /// A placeholder's name and facts still to come.
    private let nameBar = FixedFocusPlaceholder()
    private let factsBar = FixedFocusPlaceholder()
    /// A poster's caption (not grown): its name and year, as under a
    /// moving-focus card at rest.
    private let caption = UIView()
    private let captionName = UILabel()
    private let captionYear = UILabel()
    private var grown = false
    /// Its row focused (rows above and below: the cards alone).
    private var captionShown = false
    func setCaptionShown(_ shown: Bool, animated: Bool = true) {
        guard shown != captionShown else { return }
        captionShown = shown
        if animated { fadeCaption(out: !shown) } else { UIView.performWithoutAnimation { applyAlpha() } }
    }
    /// Out quickly (gone before its card has travelled far — the move's
    /// own duration carried it a long way); in as the mirror of that: over
    /// the same share of the way, at its end (`captionFadeIn`).
    static let captionFadeOut: Double = 0.08
    /// When, in a move of `duration` (the rows' no-bounce spring), the card
    /// has as much of its way left as it covered in `captionFadeOut`.
    static func captionFadeIn(duration: Double) -> Double {
        FixedFocusMotion.time(at: 1 - FixedFocusMotion.progress(captionFadeOut, duration: duration),
                              duration: duration)
    }
    /// The poster going under the box or coming out: its caption shows
    /// only the first and last 30 % of the way (it travels the box's
    /// width and more — with the captions' fades, ~40 %, it showed too
    /// much movement beside the box's info, which barely drifts; tried:
    /// 10 % — too little; 25 %).
    static let grownFadeShare: Double = 0.3
    private func fadeCaption(out: Bool, share: Double? = nil) {
        let move = rowCell?.move?.vertical?.duration ?? Motion.moveDuration
        let start = share.map { FixedFocusMotion.time(at: 1 - $0, duration: move) }
            ?? Self.captionFadeIn(duration: move)
        let gone = share.map { FixedFocusMotion.time(at: $0, duration: move) } ?? Self.captionFadeOut
        UIView.animate(withDuration: out ? gone : move - start,
                       delay: out ? 0 : start,
                       options: [out ? .curveLinear : .curveEaseOut, .beginFromCurrentState,
                                 .overrideInheritedDuration, .overrideInheritedCurve]) { self.applyAlpha() }
    }
    private var item: MetaItem?
    private var backdropFor: String?
    /// Continue Watching: a landscape card (backdrop always), with its state.
    private var landscape = false
    private let state = FixedFocusProgressView()

    /// Darkened (0…1 black over the card — not see-through).
    var dim: CGFloat = 0 {
        didSet { if dim != oldValue { dimCover.alpha = dim } }
    }
    private let dimCover = UIView()
    private let badges = FixedFocusBadges()
    /// Still loading: the placeholder card.
    private let placeholderCard = FixedFocusPlaceholder()
    /// The picture it shows on its way: the placeholder's look over it.
    private let loadingCard = FixedFocusPlaceholder()
    private var posterWaiting = false
    private var backdropWaiting = false
    struct Pictures { let backdrop: UIImage?; let logo: UIImage? }
    /// What it shows grown for `item`, its picture in (nil: none yet).
    func pictures(for item: MetaItem) -> Pictures? {
        guard backdropFor == item.id, !backdropWaiting, let picture = backdrop.image else { return nil }
        return Pictures(backdrop: picture, logo: logo.image)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        FixedFocusRing.follow(self)
        clipsToBounds = false
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = Spotlight.cornerRadius
        contentView.layer.cornerCurve = .continuous
        for view in [backdrop, poster] {
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            contentView.addSubview(view)
        }
        // A card of its own while it's narrower than its cell (sliding under
        // the box, grown): square, its edge showed beside the box.
        poster.layer.cornerRadius = Spotlight.cornerRadius
        poster.layer.cornerCurve = .continuous
        placeholderCard.isHidden = true
        contentView.addSubview(placeholderCard)
        loadingCard.isHidden = true
        contentView.addSubview(loadingCard)
        backdrop.addSubview(shade)
        backdrop.addSubview(logo)
        state.alpha = 0
        backdrop.addSubview(state)
        // The badges on the grown picture only, as the box's (posters
        // have none).
        backdrop.addSubview(badges)
        // The card's edge (on top of its pictures) and its shadow (under
        // the card, outside it).
        edge.isUserInteractionEnabled = false
        contentView.addSubview(edge)
        dimCover.backgroundColor = .black
        dimCover.alpha = 0
        dimCover.isUserInteractionEnabled = false
        contentView.addSubview(dimCover)
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outline.layer.borderWidth = FixedFocusRing.width
        // (The top bar's light — as on the box: see `FixedFocusCardEdge`.)
        outline.addSubview(outlineLight)
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.alpha = 0
        addSubview(outline)
        FixedFocusRing.attachShadow(to: outline)
        name.font = FixedFocusText.titleFont(FixedFocusMetrics.textSize)
        name.textColor = UIColor.white.withAlphaComponent(FixedFocusText.titleLevel(focused: true))
        // (Trial: no name above it, so the facts take the title's look.)
        facts.font = FixedFocusText.titleFont(FixedFocusMetrics.textSize)
        facts.textColor = UIColor.white.withAlphaComponent(FixedFocusText.titleLevel(focused: true))
        info.addSubview(name)
        info.addSubview(facts)
        FixedFocusMetrics.styleDescription(summary)
        info.addSubview(summary)
        for bar in [nameBar, factsBar] {
            bar.isHidden = true
            info.addSubview(bar)
        }
        info.alpha = 0
        info.isUserInteractionEnabled = false
        addSubview(info)
        captionName.font = FixedFocusText.titleFont(FixedFocusMetrics.captionSize)
        captionName.textColor = UIColor.white.withAlphaComponent(FixedFocusText.titleLevel(focused: false))
        captionYear.font = FixedFocusText.infoFont(FixedFocusMetrics.captionSize)
        captionYear.textColor = UIColor.white.withAlphaComponent(FixedFocusText.infoLevel(focused: false))
        caption.addSubview(captionName)
        caption.addSubview(captionYear)
        caption.isUserInteractionEnabled = false
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimCover.frame = contentView.bounds
        // Fixed sizes: the cell's width only reveals — except in an Up/Down
        // opening, where both fill the card (`shaped`). The poster centred:
        // under the box (a box-wide gap) it comes out and goes in on both
        // sides alike, in step with the cell's width — except Up/Down
        // closing (`closing`): at the card's left edge, as the landscape.
        let posterWidth = FixedFocusMetrics.posterWidth
        poster.frame = shaped || closing ? contentView.bounds
            : CGRect(x: max(0, (contentView.bounds.width - posterWidth) / 2), y: 0,
                     width: posterWidth, height: cardHeight)
        backdrop.frame = shaped ? contentView.bounds
            : CGRect(x: 0, y: 0, width: landscapeWidth, height: cardHeight)
        // Grown, the box's picture: at the box's zoom.
        backdrop.layer.contentsRect = landscape ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : FixedFocusBoxView.zoomRect
        shade.frame = backdrop.bounds
        logo.room = FixedFocusMetrics.logoRoom(width: landscapeWidth, height: cardHeight)
        outline.frame = bounds
        let lit = FixedFocusCardEdge.focusLight
        outline.layer.borderWidth = lit ? 0 : FixedFocusRing.width
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outlineLight.image = lit ? FixedFocusCardEdge.focusImage : nil
        outlineLight.frame = outline.bounds
        edge.image = FixedFocusCardEdge.rim
        // Around what the card shows: the poster — not the box-wide gap a
        // grown cell under the fixed box is (its hairline trailed into the
        // box while sliding there) — or, showing the box itself, all of it.
        let card = landscape || showsBox || shaped || closing ? contentView.bounds : poster.frame
        edge.frame = card
        contentView.bringSubviewToFront(edge)
        placeholderCard.frame = card
        loadingCard.frame = card
        let placeholder = FixedFocusPlaceholder.isPlaceholder(item)
        edge.isHidden = placeholder || loadingCard.isWaiting
        placeholderCard.isHidden = !placeholder
        poster.isHidden = placeholder
        backdrop.isHidden = placeholder
        state.frame = CGRect(x: 0, y: 0, width: landscapeWidth, height: cardHeight)
        // (Bounds and centre: it may be counter-scaled — see `apply`.)
        let infoRect = CGRect(x: FixedFocusMetrics.textIndent, y: cardHeight + FixedFocusMetrics.boxInfoGap,
                              width: landscapeWidth - 2 * FixedFocusMetrics.textIndent,
                              height: FixedFocusMetrics.infoHeight)
        info.bounds = CGRect(origin: .zero, size: infoRect.size)
        info.center = CGPoint(x: infoRect.midX, y: infoRect.midY)
        applyInfoCounterScale()
        summary.frame = CGRect(x: 0, y: FixedFocusMetrics.descriptionFrameY, width: info.bounds.width,
                               height: summary.font.lineHeight * 4 + 2)
        name.isHidden = true
        facts.frame = CGRect(x: 0, y: 0, width: info.bounds.width, height: FixedFocusMetrics.factsHeight)
        let barHeight = (FixedFocusMetrics.textSize * 0.72).rounded()
        for (bar, label, share) in [(nameBar, name, 0.5), (factsBar, facts, 0.35)] {
            bar.layer.cornerRadius = barHeight / 2
            bar.frame = CGRect(x: 0, y: label.frame.midY - barHeight / 2,
                               width: (info.bounds.width * share).rounded(), height: barHeight)
            bar.isHidden = !placeholder || bar === nameBar
        }
        // Under its poster, wherever that sits in the cell (centred: under
        // the box the cell is box-wide), so it moves with it.
        let posterLeft = max(0, (contentView.bounds.width - FixedFocusMetrics.posterWidth) / 2)
        caption.frame = CGRect(x: posterLeft + FixedFocusMetrics.textIndent, y: cardHeight + FixedFocusMetrics.infoGap,
                               width: FixedFocusMetrics.posterWidth - 2 * FixedFocusMetrics.textIndent,
                               height: FixedFocusMetrics.captionRoom - FixedFocusMetrics.infoGap)
        captionName.frame = CGRect(x: 0, y: 0, width: caption.bounds.width, height: 30)
        captionYear.frame = CGRect(x: 0, y: FixedFocusMetrics.captionLineOffset,
                                   width: caption.bounds.width, height: 30)
    }

    /// New progress for the title it already shows.
    func showProgress(_ progress: WatchProgress) {
        facts.text = progress.episodeTitle ?? facts.text
        state.show(progress)
    }

    func configure(_ item: MetaItem, index: Int, rowCell: FixedFocusRowCell,
                   progress: WatchProgress?, landscape: Bool, invisible: Bool = false,
                   cardHeight: CGFloat = FixedFocusMetrics.height, badges: [CardBadge] = []) {
        itemIndex = index
        self.cardHeight = cardHeight
        self.rowCell = rowCell
        self.item = item
        self.landscape = landscape
        self.invisible = invisible
        contentView.isHidden = invisible
        backdropFor = nil
        self.badges.show(invisible || progress != nil ? [] : badges)
        if invisible {
            // The billboard's focus target: nothing to show or load.
            for view in [poster, backdrop, logo] { FixedFocusImages.load(nil, into: view, maxDimension: 0) }
            setOutline(false)
            info.alpha = 0
            return
        }
        setNeedsLayout()
        if landscape {
            // Landscape: the art right away. Continue Watching: its art is
            // the still or the backdrop (Settings → Episode thumbnails,
            // already applied to the item), no logo, the state line is the
            // card's only text; other rows: the logo.
            backdropFor = item.id
            shade.isHidden = item.type == "collection"
            FixedFocusImages.load(item.background ?? item.poster,
                                  into: backdrop, maxDimension: PictureSize.landscape,
                                  waiting: { [weak self] in self?.backdropWaiting = $0; self?.updateWaiting() })
            FixedFocusImages.load(progress == nil ? item.logo : nil, into: logo,
                                  maxDimension: PictureSize.cardLogo)
            FixedFocusImages.load(nil, into: poster, maxDimension: 0,
                                  waiting: { [weak self] in self?.posterWaiting = $0 })
            state.show(progress)
            state.alpha = progress == nil ? 0 : 1
            name.text = item.name
            facts.text = progress?.episodeTitle
                ?? FixedFocusShowInfo.factsLine(item)
            return
        }
        state.alpha = 0
        shade.isHidden = false
        captionName.text = item.name
        captionYear.text = item.year
        applyAlpha()
        FixedFocusImages.load(item.poster ?? item.background, into: poster,
                              maxDimension: PictureSize.poster,
                              waiting: { [weak self] in self?.posterWaiting = $0; self?.updateWaiting() })
        FixedFocusImages.load(nil, into: backdrop, maxDimension: 0,
                              waiting: { [weak self] in self?.backdropWaiting = $0 })
        FixedFocusImages.load(nil, into: logo, maxDimension: 0)
        name.text = item.name
        facts.text = FixedFocusShowInfo.factsLine(item)
    }

    /// The picture it shows still on its way: the placeholder's look, no
    /// edge (the box's backdrop under the fixed box: the box shows it).
    private func updateWaiting() {
        // Opening with the landscape still on its way, the poster stays
        // (`backdropArrived`): the placeholder only with neither.
        let waiting = landscape ? backdropWaiting
            : showsBox ? backdropWaiting && posterWaiting : posterWaiting
        loadingCard.follow(waiting: waiting)
        setNeedsLayout()
    }

    /// The cell's outline.
    private func setOutline(_ on: Bool) {
        outline.alpha = on ? 1 : 0
    }

    /// The billboard's cells: focus targets only, nothing drawn.
    private var invisible = false
    /// The card's height (the landscape picture's width follows).
    private var cardHeight = FixedFocusMetrics.height
    private var landscapeWidth: CGFloat { FixedFocusMetrics.landscapeWidth(height: cardHeight) }
    /// The third line under the grown cell (as under the box).
    private let summary = TopAlignedLabel()

    /// Left of the box: dimmed.
    func setPast(_ past: Bool) {
        self.past = past
        applyAlpha()
    }

    /// Waiting under the billboard: not shown (still focusable — it's the
    /// cell's content that is transparent, not the cell).
    func setConcealed(_ concealed: Bool) {
        self.concealed = concealed
        applyAlpha()
    }

    private var past = false
    private var concealed = false

    private func applyAlpha() {
        contentView.alpha = concealed || underPressedBox ? 0 : past ? FixedFocusMetrics.previousAlpha : 1
        // The caption: only under a poster (not the box, a landscape card,
        // a placeholder) in
        // the box's row, not left of the box (its sliver at the edge).
        let plain = captionShown && !past && !invisible && !landscape && !grown
            && !FixedFocusPlaceholder.isPlaceholder(item)
        caption.alpha = plain && !concealed && !underPressedBox ? 1 : 0
    }

    /// Showing the box itself (grown, not under the fixed box).
    private var showsBox = false

    /// The layout's scale for this card (the grown title at the lifted box's
    /// size). Its info keeps its size and sits where the box's does — the
    /// card's own scale undone, moved down by the overhang — or at the
    /// handover to the box it jumped back.
    private var layoutScale: CGFloat = 1
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        layoutScale = layoutAttributes.transform.a == 0 ? 1 : layoutAttributes.transform.a
        applyInfoCounterScale(size: layoutAttributes.size)
    }

    private func applyInfoCounterScale(size: CGSize? = nil) {
        let s = layoutScale
        guard s != 1 else { info.transform = .identity; return }
        let size = size ?? bounds.size
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let overhang = cardHeight * (s - 1) / 2
        // Net for the info: moved down by `overhang`, unscaled.
        let tx = -(s - 1) * (info.center.x - centre.x) / s
        let ty = (overhang - (s - 1) * (info.center.y - centre.y)) / s
        info.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: 1 / s, y: 1 / s)
    }
    /// Under the pressed fixed box (it shrinks a little): hidden, or its
    /// edges showed around the box.
    func setUnderPressedBox(_ under: Bool) {
        underPressedBox = under
        applyAlpha()
    }
    private var underPressedBox = false

    /// The card's rim (see `FixedFocusCardEdge`).
    private let edge = UIImageView()
    private let outlineLight = UIImageView()

    /// Grown: the backdrop shows — unless the fixed box shows it
    /// (`contentHidden`), then the cell is just a box-wide gap. The info
    /// shows under every grown cell (it travels with its title).
    func setGrown(_ grown: Bool, contentHidden: Bool) {
        if invisible { return }
        if grown != self.grown {
            self.grown = grown
            fadeCaption(out: grown, share: Self.grownFadeShare)
        }
        if grown, let item {
            summary.text = FixedFocusPlaceholder.isPlaceholder(item) ? nil : FixedFocusMetrics.descriptionText(item)
        }
        if landscape {
            // Continue Watching: always the landscape card; the outline only
            // while it shows itself (under the fixed box: none).
            poster.alpha = 0
            backdrop.alpha = 1
            setOutline(grown && !contentHidden)
            info.alpha = grown && !contentHidden ? 1 : 0
            return
        }
        if grown, let item, backdropFor != item.id {
            backdropFor = item.id
            FixedFocusImages.load(item.background ?? item.poster, into: backdrop,
                                  maxDimension: PictureSize.landscape,
                                  waiting: { [weak self] waiting in
                guard let self else { return }
                self.backdropWaiting = waiting
                self.updateWaiting()
                if !waiting { self.backdropArrived() }
            })
            FixedFocusImages.load(item.logo, into: logo, maxDimension: PictureSize.cardLogo)
        }
        // Under the fixed box (contentHidden) the poster simply stays: the
        // box covers it — no fade, only movement. It only gives way to the
        // backdrop while the cell itself shows the box (Up/Down opening).
        let shows = grown && !contentHidden
        let changes = shows != showsBox
        if changes { showsBox = shows; updateWaiting(); setNeedsLayout() }
        let move = rowCell?.move
        if let duration = move?.reshaping, changes {
            if shows { reshape(duration: duration) } else { close(duration: duration) }
        } else if !closing || changes {
            if closing { endClose() }
            if shaped, move?.reshaping == nil { unshape() }
            poster.alpha = shows && !backdropWaiting ? 0 : 1
            backdrop.alpha = shows ? 1 : 0
        }
        // A placeholder (`FixedFocusRows.placeholderRows`): the empty card
        // only — no shade, no outline (nothing has focus yet); the wide one
        // its info's bars.
        if item?.id.hasPrefix("placeholder-") == true {
            shade.isHidden = true
            info.alpha = grown ? 1 : 0
            setOutline(false)
            return
        }
        // The info too only while the cell shows itself (Up/Down); under the
        // box, the box's own info drifts in place.
        info.alpha = shows ? 1 : 0
        if let vertical = move?.vertical {
            // Up/Down: the outlines hand over gradually: the old one fades out over
            // the first 70 %, the new one in over the last 70 %, linearly.
            let span = vertical.duration * 0.7
            UIView.animate(withDuration: span, delay: shows ? vertical.duration - span : 0,
                           options: [.curveLinear, .overrideInheritedDuration,
                                     .overrideInheritedCurve, .beginFromCurrentState]) {
                self.setOutline(shows)
            }
        } else {
            setOutline(shows)
        }
    }

    /// Up/Down opening: ONE shape — both pictures fill the growing card
    /// (centre cropped), on the move's own spring, the landscape crossfading
    /// over the poster early. Closing: `close`.
    private var shaped = false
    private func reshape(duration: Double) {
        if closing { endClose() }
        let from = contentView.layer.presentation()?.bounds ?? contentView.bounds
        UIView.performWithoutAnimation {
            for view in [poster, backdrop, edge, loadingCard, placeholderCard] as [UIView] {
                view.layer.removeAllAnimations()
                view.frame = from
            }
            backdrop.alpha = 1
        }
        shaped = true
        setNeedsLayout()
        layoutIfNeeded()
        // Its landscape not in yet: the poster stays, filling the card, until
        // it is (`backdropArrived`) — no placeholder, no pop.
        guard !backdropWaiting else { return }
        let start = FixedFocusMotion.time(at: 0.25, duration: duration)
        let end = FixedFocusMotion.time(at: 0.75, duration: duration)
        UIView.animate(withDuration: end - start, delay: start,
                       options: [.overrideInheritedDuration, .overrideInheritedCurve,
                                 .beginFromCurrentState, .curveEaseInOut]) {
            self.poster.alpha = 0
        }
    }
    /// The landscape in late, the card showing itself: it fades in over
    /// the poster.
    private func backdropArrived() {
        guard showsBox, !closing, poster.alpha > 0 else { return }
        UIView.animate(withDuration: Motion.fadeDuration, delay: 0,
                       options: [.overrideInheritedDuration, .overrideInheritedCurve,
                                 .beginFromCurrentState, .curveEaseInOut]) {
            self.poster.alpha = 0
        }
    }
    /// Up/Down closing: the landscape stays at the card's left edge,
    /// cropped as the card narrows, the edge on it; the poster stretched to
    /// fill the card (not zoomed: a 2:3 picture can't fill 16:9 without one
    /// or the other), crossfading in over it from half to 90 % of the way
    /// (`closeStretch`; from a quarter to three quarters, the stretch
    /// showed too much) — less and less stretched as the card closes, its
    /// own shape at the end.
    /// While it runs, a later pass in the same move (the row's relayout)
    /// leaves the alphas alone.
    static let closeStretch: ClosedRange<Double> = 0.5...0.9
    private var closing = false
    private var closeID = 0
    private func close(duration: Double) {
        let from = contentView.layer.presentation()?.bounds ?? contentView.bounds
        closeID += 1
        let id = closeID
        // The stretched poster stays until the card has settled (1.5 × the
        // move: within a fraction of a point) — undone earlier, it jumped to
        // its own width.
        let settled = CACurrentMediaTime() + 1.5 * duration
        closing = true
        shaped = false
        UIView.performWithoutAnimation {
            for view in [poster, backdrop, edge, loadingCard, placeholderCard] as [UIView] {
                view.layer.removeAllAnimations()
                view.frame = from
            }
            poster.contentMode = .scaleToFill
            backdrop.frame = CGRect(x: 0, y: 0, width: landscapeWidth, height: cardHeight)
            backdrop.alpha = 1
            poster.alpha = 1
        }
        setNeedsLayout()
        layoutIfNeeded()
        // Core Animation: a nested UIView animation takes the move's spring.
        let start = FixedFocusMotion.time(at: Self.closeStretch.lowerBound, duration: duration)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + start
        fade.duration = FixedFocusMotion.time(at: Self.closeStretch.upperBound, duration: duration) - start
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.closing, self.closeID == id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, settled - CACurrentMediaTime())) { [weak self] in
                guard let self, self.closing, self.closeID == id else { return }
                self.endClose()
            }
        }
        poster.layer.add(fade, forKey: "closeFade")
        CATransaction.commit()
    }
    private func endClose() {
        closing = false
        poster.contentMode = .scaleAspectFill
        poster.layer.removeAnimation(forKey: "closeFade")
        UIView.performWithoutAnimation {
            backdrop.alpha = showsBox ? 1 : 0
            setNeedsLayout()
            layoutIfNeeded()
        }
    }
    /// Back to the fixed sizes (the next move that isn't Up/Down).
    private func unshape() {
        shaped = false
        UIView.performWithoutAnimation {
            for view in [poster, backdrop, edge, loadingCard, placeholderCard] as [UIView] {
                view.layer.removeAllAnimations()
            }
            setNeedsLayout()
            layoutIfNeeded()
        }
    }
}

/// The poster row's layout: every position computed exactly — title i at
/// `inset + i × pitch`, everything after the wide (focused) title shifted
/// by its extra width. (UIKit's flow layout spread the posters out as soon
/// as one cell was wider than the rest.)
final class FixedFocusStripLayout: UICollectionViewLayout {
    /// The row extends this far beyond the screen on both sides; positions
    /// are shifted by it (so on screen nothing moves).
    static let overscan: CGFloat = 1200
    /// The grown title's index (nil: all posters).
    var wideIndex: () -> Int? = { nil }
    /// The cards' width (posters; landscape: box-wide) and height.
    var cardWidth: () -> CGFloat = { FixedFocusMetrics.posterWidth }
    var cardHeight: () -> CGFloat = { FixedFocusMetrics.height }
    private var frames: [CGRect] = []
    private var contentWidth: CGFloat = 0
    private var height = FixedFocusMetrics.height

    override func prepare() {
        super.prepare()
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let wide = wideIndex()
        let card = cardWidth()
        height = cardHeight()
        let pitch = card + FixedFocusMetrics.gap
        let extra = FixedFocusMetrics.boxWidth - card
        // A lifted box overhangs its spot: its neighbours step
        // aside by as much, keeping the usual gap.
        let overhang = FixedFocusMetrics.boxWidth * (FixedFocusMetrics.boxScale - 1) / 2
        frames = (0..<count).map { i in
            var x = Self.overscan + FixedFocusMetrics.inset + CGFloat(i) * pitch
            if let wide, i > wide { x += extra + overhang }
            if let wide, i < wide { x -= overhang }
            let width = i == wide ? FixedFocusMetrics.boxWidth : card
            return CGRect(x: x, y: 0, width: width, height: height)
        }
        // Room after the last title so it too can reach the spot.
        contentWidth = (frames.last?.maxX ?? 0) + 1920 + 2 * Self.overscan
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        frames.indices.compactMap { i in
            frames[i].intersects(rect) ? attributes(i) : nil
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    private func attributes(_ i: Int) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
        a.frame = frames[i]
        // The grown title at the box's size (lifted): with its
        // size and place, so opening into the box and growing are one move.
        if i == wideIndex() {
            let scale = FixedFocusMetrics.boxScale
            if scale != 1 {
                a.transform = CGAffineTransform(scaleX: scale, y: scale)
                a.zIndex = 1
            }
        }
        return a
    }
}

/// The row list's layout: no scrolling — every row placed around the
/// focused one. The focused row at the fixed spot; the row above so its
/// posters' lower third shows at the top; the row below so the original
/// preview height shows at the bottom; the rest off screen, a row apart.
/// On Up/Down the layout is recomputed and the rows glide to their places.
final class FixedFocusRowsLayout: UICollectionViewLayout {
    var focusedRow: () -> Int = { 0 }
    /// The focused row's name, on screen.
    var rowTop: () -> CGFloat = { FixedFocusMetrics.rowTop }
    /// How much lower than usual the focused row stands (the row under the
    /// billboard): `rowTop()` includes it.
    var rowDrop: () -> CGFloat = { 0 }
    /// See `FixedFocusRows.rigidRest`.
    var rigidRest: () -> CGFloat? = { nil }
    /// The billboard's own distance up at a depth, if it has one.
    var billboardUp: (Int) -> CGFloat? = { _ in nil }
    /// A row's cards' height (one size, but for a side-info row).
    var cardHeight: (Int) -> CGFloat = { _ in FixedFocusMetrics.height }
    /// A row's cards this much lower under its name (a line under it).
    var titleExtra: (Int) -> CGFloat = { _ in 0 }
    /// How much of the rows above and below shows.
    var peeks: () -> (above: CGFloat, below: CGFloat) = {
        (FixedFocusMetrics.aboveVisible, FixedFocusMetrics.belowVisible)
    }
    /// How far a row's drawing reaches beyond its name and cards (a
    /// collection's panel): rows keep that much more room between them.
    var reach: (Int) -> (above: CGFloat, below: CGFloat) = { _ in (0, 0) }
    /// How much of a row's height is below its cards (a destination row's
    /// captions): the row above shows its CARDS' lower part, as any row.
    var belowCards: (Int) -> CGFloat = { _ in 0 }
    /// How far a focused row draws, from its anchor (its name; a panel's
    /// top) to the end of what shows under its cards (the fixed box's info,
    /// captions, a panel's edge): the next row's name the peek gap below it.
    var drawnHeight: (Int) -> CGFloat = { _ in
        FixedFocusMetrics.titleHeight + FixedFocusMetrics.height + FixedFocusMetrics.infoGap + FixedFocusMetrics.infoHeight
    }
    /// The row below always shows at least this much of its cards (a tall
    /// focused row pushes it down only so far).
    static let minimumPeek: CGFloat = 70
    /// A custom row's content height from its anchor (nil: not one, or not
    /// measured — see `FixedFocusCustomRow.contentHeight`). Coming into it,
    /// the rows only scroll as far as needed to show it all.
    var customContent: (Int) -> CGFloat? = { _ in nil }
    /// The Featured row (the billboard), if any.
    var featuredRow: () -> Int? = { nil }
    /// Billboard in focus, scrolling to or from the rows: the rows below are
    /// AWAY — at their places with the next row in focus, a whole scroll
    /// lower (off the screen), so they move exactly as far as the picture.
    /// At rest under the billboard they wait at the bottom edge instead.
    var belowAway: () -> Bool = { false }
    /// How far everything scrolls between the billboard and the rows: the
    /// picture, all the way off the screen.
    static let billboardTravel: CGFloat = StagePictureView.pictureSize.height
    /// Under the billboard the next row waits with its (hidden) cards just
    /// on the screen at the bottom edge: enough for tvOS to focus them.
    static let restingCardsOnScreen: CGFloat = 2
    /// The next row's name on the billboard sits here (bottom left, in line
    /// with the dots) — see the controller's `titleLift`.
    static var nextNameY: CGFloat {
        let dotsMid = TitleBlock.hintY(screenHeight: 1080) + SectionHint.size * 1.3 / 2
        return (dotsMid - FixedFocusMetrics.titleLine / 2).rounded()
    }
    /// One row below the billboard its lower edge still shows this far down
    /// (never below the focused row's name, so the rows' entry stays off
    /// the screen).
    static func topPeek(focusY: CGFloat) -> CGFloat { FixedFocusMetrics.billboardTopPeek }
    /// How far everything moves between the billboard and the rows: the
    /// picture, the rows and the billboard's text alike.
    static func scrollDistance(focusY: CGFloat) -> CGFloat { billboardTravel - topPeek(focusY: focusY) }
    /// How far the billboard has gone up with focus `depth` rows below it:
    /// ONE formula for its picture (the Featured row) and its text and dots
    /// (SwiftUI, above the rows), so they move as one.
    static func billboardScroll(depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        return scrollDistance(focusY: FixedFocusMetrics.rowTop)
            + (depth > 1 ? FixedFocusMetrics.billboardStripDrop + CGFloat(depth - 1) * FixedFocusMetrics.rowPitch : 0)
    }
    /// A RIGID billboard's (see `FixedFocusRows.rigidRest`): the first row
    /// from its rest up to the spot, then a row at a time.
    static func billboardScroll(depth: Int, rigidRest rest: CGFloat, rowTop: CGFloat = FixedFocusMetrics.rowTop) -> CGFloat {
        guard depth > 0 else { return 0 }
        return rest - rowTop + CGFloat(depth - 1) * FixedFocusMetrics.rowPitch
    }
    /// The list extends this far beyond the screen, above and below (see
    /// the controller's `viewDidLayoutSubviews`); rows are placed in screen
    /// coordinates shifted by it.
    static let overscan: CGFloat = 1100
    private var frames: [CGRect] = []
    /// The rows' places before the last change: a row coming on screen in
    /// a move starts from there (and one leaving goes on to its new place)
    /// — the rows scroll, as one. (By default they faded in at the new
    /// place and out at the old: on a move of several rows, rows ran
    /// through each other.)
    private var previousFrames: [CGRect] = []

    override func prepare() {
        super.prepare()
        let old = frames
        defer { if frames != old { previousFrames = old } }
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let f = focusedRow()
        let heights = (0..<count).map { FixedFocusMetrics.titleHeight + titleExtra($0) + cardHeight($0) }
        let focusY = rowTop()
        // (The list's own height: the whole screen on Home.)
        let screen = (collectionView?.bounds.height).map { $0 - 2 * Self.overscan } ?? 1080
        let peek = peeks()
        let reaches = (0..<count).map(reach)
        /// The lowest the row below the focused one may start: its name and
        /// the minimum peek of its cards still on the screen.
        let lowestBelow = screen - FixedFocusMetrics.titleHeight - Self.minimumPeek
        /// Every row's top with row `f` focused: the focused one at the spot;
        /// the next the same gap below the end of what the focused one draws
        /// (whatever its height — so the peek varies, the gap doesn't), but
        /// never lower than its minimum peek; the ones after it the same gap
        /// apart; the one before peeking down from the top, the rest a row
        /// apart above it — each row's reach (a panel's) included, so no
        /// drawing overlaps the next. A row's ANCHOR
        /// is the top of what it draws (its name; a collection's panel).
        func tops(_ f: Int) -> [CGFloat] {
            var y = [CGFloat](repeating: 0, count: count)
            guard count > 0 else { return y }
            let f = min(max(f, 0), count - 1)
            y[f] = focusY + reaches[f].above
            if f + 1 < count {
                let after = focusY + drawnHeight(f) + FixedFocusMetrics.peekGap
                y[f + 1] = min(after, lowestBelow) + reaches[f + 1].above
            }
            // Further down: the same gap below each row (its height, captions
            // in) — a row coming up to be next doesn't move again.
            if f + 2 < count {
                for r in (f + 2)..<count {
                    y[r] = y[r - 1] + heights[r - 1] + reaches[r - 1].below + FixedFocusMetrics.peekGap
                        + reaches[r].above
                }
            }
            if f > 0 { y[f - 1] = peek.above - heights[f - 1] - reaches[f - 1].below + belowCards(f - 1) }
            // Further up: the same gap above each row, below the cards of the
            // one over it (out of focus, its captions don't show).
            if f > 1 {
                for r in stride(from: f - 2, through: 0, by: -1) {
                    y[r] = y[r + 1] - reaches[r + 1].above - FixedFocusMetrics.peekGap - reaches[r].below
                        - heights[r] + belowCards(r)
                }
            }
            return y
        }
        let focusedTops = tops(f)
        func normal(_ r: Int, _ f: Int) -> CGFloat {
            f == self.focusedRow() ? focusedTops[r] : tops(f)[r]
        }
        let featured = featuredRow()
        /// Focus in a custom row (Details' About), from a row above that
        /// isn't the billboard: the rows as with that row in focus, all moved
        /// up by one distance — just enough that its content ends
        /// `customBottomGap` above the screen's bottom (never past the usual
        /// spot; not at all if it already shows).
        let customScroll: (tops: [CGFloat], by: CGFloat)? = {
            guard count > 0, f > 0, f < count, featured != f - 1, let content = customContent(f) else { return nil }
            let before = tops(f - 1)
            let target = screen - FixedFocusMetrics.customBottomGap - content
            let top = min(before[f], max(focusY, target))
            return (before, before[f] - top)
        }()
        frames = (0..<count).map { r in
            let y: CGFloat
            if let featured, f == featured, r != featured {
                // Under the billboard, as with the next row in focus: AWAY a
                // whole scroll lower (the picture's distance: one page), or
                // at rest with the next row's hidden cards just touching the
                // bottom edge (see the controller's `rowConcealed`).
                let next = featured + 1
                if let rest = rigidRest() {
                    // Rigid: the rows as with the next one in focus, lower
                    // by exactly the scroll.
                    y = normal(r, next) + rest - focusY
                } else if belowAway() {
                    y = normal(r, next) + Self.billboardScroll(depth: 1)
                } else {
                    let cardsTop = screen - Self.restingCardsOnScreen
                    y = normal(r, next) + cardsTop - FixedFocusMetrics.titleHeight - reaches[next].above - focusY
                }
            } else if let featured, r == featured, f > featured {
                // Scrolled away above: the picture and its edge off the top
                // — one row down, its lower edge still shows (as the row
                // above does).
                // (From the usual spot, not the dropped one: the picture's
                // frame is laid out from it.)
                y = focusY - rowDrop() - (billboardUp(f - featured) ?? rigidRest().map {
                    Self.billboardScroll(depth: f - featured, rigidRest: $0, rowTop: focusY)
                } ?? Self.billboardScroll(depth: f - featured))
            } else if let scroll = customScroll {
                // Into a custom row: the rows as they were, scrolled up just
                // far enough to show it all.
                y = scroll.tops[r] - scroll.by
            } else {
                y = normal(r, f)
            }
            return CGRect(x: 0, y: y + Self.overscan, width: 1920, height: heights[r])
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: 1920, height: 1080 + 2 * Self.overscan)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        frames.indices.compactMap { frames[$0].intersects(rect) ? attributes($0) : nil }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let r = itemIndexPath.item
        guard previousFrames.count == frames.count, frames.indices.contains(r) else {
            return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        }
        let a = attributes(r)
        a.frame = previousFrames[r]
        return a
    }

    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let r = itemIndexPath.item
        guard previousFrames.count == frames.count, frames.indices.contains(r) else {
            return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
        }
        return attributes(r)
    }

    private func attributes(_ r: Int) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: r, section: 0))
        a.frame = frames[r]
        // The billboard's picture lies under the rows scrolling over it.
        if r == featuredRow() { a.zIndex = -1 }
        return a
    }
}

final class FixedFocusPanelView: UIView {
    /// In the row cell: around the name, the tiles and the info under the
    /// box, from a little left of the box almost to the right edge.
    static func frame(cardHeight: CGFloat) -> CGRect {
        let reach = FixedFocusMetrics.panelReach
        let x = FixedFocusMetrics.inset - FixedFocusMetrics.panelPad
        return CGRect(x: x, y: -reach.above, width: 1920 - 2 * x,
                      height: reach.above + FixedFocusMetrics.titleHeight + cardHeight + reach.below)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = FixedFocusMetrics.panelRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        apply(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The title background's colour (`TitleBackground`): the fill and edge
    /// change over `fade`, on the background's own curve; nil: neutral.
    func show(_ color: UIColor?, fade: Double, follows: Bool) {
        let shown = layer.presentation() ?? layer
        let from = [("backgroundColor", shown.backgroundColor), ("borderColor", shown.borderColor)]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(color)
        CATransaction.commit()
        guard fade > 0, window != nil else { return }
        for (key, old) in from {
            let change = CABasicAnimation(keyPath: key)
            change.fromValue = old
            change.duration = fade
            change.timingFunction = follows ? FixedFocusTint.focusTiming
                : CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(change, forKey: key)
        }
    }

    private func apply(_ color: UIColor?) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let color, color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            backgroundColor = UIColor(white: 1, alpha: 0.06)
            layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
            return
        }
        backgroundColor = UIColor(hue: h, saturation: min(s, 0.75), brightness: 0.26, alpha: 0.92)
        layer.borderColor = UIColor(hue: h, saturation: min(s, 0.6), brightness: 0.62, alpha: 0.7).cgColor
    }
}

/// A card's state line, laid over the whole card: the player's bar
/// (`Spotlight.stateBarHeight`) at the foot, above it "S1:E5" on the left
/// and "20m left" / "Up Next" / "Watched" at its end.
final class FixedFocusProgressView: UIView {
    private let episode = UILabel()
    private let remaining = UILabel()
    private let barShadow = UIView()
    private let track = UIView()
    private let fill = UIView()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        episode.font = .systemFont(ofSize: Spotlight.stateTextSize, weight: .medium)
        remaining.font = .monospacedDigitSystemFont(ofSize: Spotlight.stateTextSize, weight: .medium)
        for label in [episode, remaining] {
            label.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.8
            label.layer.shadowRadius = 8
            label.layer.shadowOffset = .zero
            addSubview(label)
        }
        // The player's: a capsule at 25 %, the fill at 56 % cut flat, a soft shadow.
        barShadow.layer.shadowColor = UIColor.black.cgColor
        barShadow.layer.shadowOpacity = 0.4
        barShadow.layer.shadowRadius = 4
        barShadow.layer.shadowOffset = .zero
        track.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        track.layer.cornerRadius = Spotlight.stateBarHeight / 2
        track.clipsToBounds = true
        fill.backgroundColor = UIColor.white.withAlphaComponent(0.56)
        track.addSubview(fill)
        addSubview(barShadow)
        addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A state given as such (Details' episodes): the label and the text,
    /// a bar (in progress) or nothing.
    func show(_ state: FixedFocusCardState) {
        episode.text = state.label
        remaining.text = state.right
        fraction = CGFloat(state.fraction ?? 0)
        track.isHidden = state.fraction == nil
        setNeedsLayout()
    }

    func show(_ entry: WatchProgress?) {
        guard let entry else { return }
        episode.text = entry.season.flatMap { s in entry.episode.map { "S\(s):E\($0)" } }
        let started = entry.isStarted
        remaining.text = started ? (entry.remainingTimeText.map { "\($0) left" } ?? "In progress") : "Up Next"
        fraction = started ? CGFloat(entry.fraction) : 0
        track.isHidden = !started
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Spotlight.stateInset
        let width = bounds.width - inset * 2
        let barH = Spotlight.stateBarHeight
        let barTop = bounds.height - inset - barH
        episode.sizeToFit()
        remaining.sizeToFit()
        // Both on one baseline, `stateBaselineGap` above the bar.
        let lineBottom = barTop - Spotlight.stateBaselineGap - episode.font.descender
        remaining.frame = CGRect(x: inset + width - remaining.bounds.width, y: lineBottom - remaining.bounds.height,
                                 width: remaining.bounds.width, height: remaining.bounds.height)
        episode.frame = CGRect(x: inset, y: lineBottom - episode.bounds.height,
                               width: max(min(episode.bounds.width, width - remaining.bounds.width - 16), 0),
                               height: episode.bounds.height)
        track.frame = CGRect(x: inset, y: barTop, width: max(width, 0), height: barH)
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * min(max(fraction, 0), 1), height: barH)
        barShadow.frame = track.frame
        barShadow.isHidden = track.isHidden
        barShadow.layer.shadowPath = UIBezierPath(roundedRect: barShadow.bounds, cornerRadius: barH / 2).cgPath
    }
}

/// The Left/Right and Up/Down curves. All through
/// `UIView.animate` — the only animation collection views follow for their
/// cells' size changes.
@MainActor
enum FixedFocusMotion {
    /// Cards whose content is new (Search's results, the shelf's links after
    /// Refresh) swell a little and settle — the Apple TV app's sign that
    /// they changed — all at once, no cascade; on the cards' content, so a
    /// focused card's growth stays.
    static func pulse(_ cells: [UICollectionViewCell]) {
        let swell = CAKeyframeAnimation(keyPath: "transform.scale")
        swell.values = [1, pulseScale, 1]
        swell.keyTimes = [0, 0.4, 1]
        swell.duration = pulseDuration
        swell.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        for cell in cells {
            cell.contentView.layer.add(swell, forKey: "pulse")
        }
    }

    private static let pulseScale: CGFloat = 1.02
    private static let pulseDuration: CFTimeInterval = 0.35

    /// A focus movement (Left/Right and Up/Down alike) on UIKit's own
    /// spring (duration + bounce 0): a new press during the move carries
    /// its speed on instead of starting from rest. (Always UIView.animate:
    /// collection views only animate their cells' size changes inside it —
    /// under a property animator they jumped.)
    static func run(duration: Double,
                    animations: @escaping () -> Void,
                    completion: @escaping (Bool) -> Void) {
        UIView.animate(springDuration: duration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: animations, completion: completion)
    }

    /// How far `run`'s spring of `duration` has gone at time `t` (0…1):
    /// 1 − (1 + ωt)·e^(−ωt), ω = 2π / duration.
    static func progress(_ t: Double, duration: Double) -> Double {
        let omega = 2 * Double.pi / duration
        return 1 - (1 + omega * t) * exp(-omega * t)
    }

    /// When `run`'s spring of `duration` has covered `share` of its way.
    static func time(at share: Double, duration: Double) -> Double {
        var low = 0.0, high = duration
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if progress(mid, duration: duration) < share { low = mid } else { high = mid }
        }
        return low
    }

    /// Between the billboard and the rows: a little longer than a row step
    /// (it moves further).
    static let billboardScroll: Double = 0.6

    /// `run`'s move for SwiftUI views moving with it (the billboard's text
    /// and dots): SwiftUI's spring is UIKit's system spring.
    static func animation(duration: Double) -> Animation {
        .spring(duration: duration, bounce: 0)
    }

    /// Left/Right, for things moving with the row (the box's drift).
    static func horizontal(_ animations: @escaping () -> Void, completion: @escaping () -> Void) {
        run(duration: Motion.moveDuration, animations: animations, completion: { _ in completion() })
    }
}

/// A card's badges (`HomeRow.badges(for:)`): dark plates at the picture's
/// top left, a symbol and the words in sentence case. Only on the fixed box (and the grown
/// card handing over to it). Side by side where they fit, else stacked.
/// Part of the art: it fills its picture and grows with it.
final class FixedFocusBadges: UIView {
    static let inset: CGFloat = 16
    static let gap: CGFloat = 8
    private var plates: [Plate] = []
    private var shown: [CardBadge] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if let superview { frame = superview.bounds }
    }

    func show(_ badges: [CardBadge]) {
        isHidden = badges.isEmpty
        guard badges != shown else { return }
        shown = badges
        while plates.count < badges.count {
            let plate = Plate()
            addSubview(plate)
            plates.append(plate)
        }
        for (index, plate) in plates.enumerated() {
            plate.isHidden = index >= badges.count
            if index < badges.count { plate.show(badges[index]) }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.inset, gap = Self.gap
        let room = max(0, bounds.width - 2 * inset)
        let showing = plates.prefix(shown.count)
        let sizes = showing.map { $0.fitting(room) }
        let row = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, sizes.count - 1))
        let sideBySide = row <= room
        var x = inset
        var y = inset
        for (plate, size) in zip(showing, sizes) {
            plate.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            if sideBySide { x += size.width + gap } else { y += size.height + gap }
        }
    }

    static func symbol(_ kind: CardBadge.Kind) -> String {
        switch kind {
        case .news: return "sparkles"
        case .returns: return "calendar"
        case .finale: return "flag.checkered"
        case .person: return "person.fill"
        case .gem: return "diamond"
        case .acclaimed: return "laurel.leading"
        case .limited: return "square.stack"
        case .top10: return "chart.bar.fill"
        case .taste: return "heart"
        }
    }

    /// One badge: a dark plate, a hairline edge, the symbol a level under
    /// the words.
    private final class Plate: UIView {
        static let padding = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        static let symbolGap: CGFloat = 10
        static let font = UIFont.systemFont(ofSize: 26, weight: .medium)
        private let symbol = UIImageView()
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = UIColor.black.withAlphaComponent(0.65)
            layer.cornerRadius = 10
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
            symbol.contentMode = .center
            symbol.tintColor = UIColor.white.withAlphaComponent(FixedFocusText.body)
            symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
            label.font = Self.font
            label.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
            label.lineBreakMode = .byTruncatingTail
            addSubview(symbol)
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ badge: CardBadge) {
            symbol.image = UIImage(systemName: FixedFocusBadges.symbol(badge.kind))
            label.text = badge.text
            setNeedsLayout()
        }

        private var symbolWidth: CGFloat { max(26, symbol.image?.size.width ?? 0) }

        /// Its size, at most `room` wide (the words cut short past it).
        func fitting(_ room: CGFloat) -> CGSize {
            let pad = Self.padding
            let text = label.intrinsicContentSize
            let width = pad.left + symbolWidth + Self.symbolGap + text.width + pad.right
            return CGSize(width: min(room, width.rounded(.up)),
                          height: (Self.font.lineHeight + pad.top + pad.bottom).rounded(.up))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let pad = Self.padding
            let height = bounds.height - pad.top - pad.bottom
            symbol.frame = CGRect(x: pad.left, y: pad.top, width: symbolWidth, height: height)
            let textX = symbol.frame.maxX + Self.symbolGap
            label.frame = CGRect(x: textX, y: pad.top, width: max(0, bounds.width - textX - pad.right), height: height)
        }
    }
}
