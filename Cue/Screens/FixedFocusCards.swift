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
        // The art and what's on it: dark in both appearances (`CueInk`).
        card.overrideUserInterfaceStyle = .dark
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
        name.textColor = CueInk.ui(FixedFocusText.primary)
        name.numberOfLines = 2
        // As on the billboard: the facts bright, the tagline quiet and italic.
        facts.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .medium)
        facts.textColor = CueInk.ui(FixedFocusText.body)
        tagline.font = UIFont(descriptor: UIFont.systemFont(ofSize: FixedFocusMetrics.textSize)
            .fontDescriptor.withSymbolicTraits(.traitItalic) ?? UIFont.systemFont(ofSize: FixedFocusMetrics.textSize).fontDescriptor,
                              size: FixedFocusMetrics.textSize)
        tagline.textColor = CueInk.ui(FixedFocusText.secondary)
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
        let total = titleHeight + FixedFocusBillboardText.logoToChips + line + gap + line + gap + 30
        var y = max(24, (bounds.height - total) / 2)
        logo.frame = CGRect(x: x, y: y, width: width * 0.7, height: Self.logoHeight)
        name.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + FixedFocusBillboardText.logoToChips
        chips.view.frame = CGRect(x: x, y: y, width: width, height: line)
        y += line + gap
        facts.frame = CGRect(x: x, y: y, width: width, height: line)
        y += line + gap
        tagline.frame = CGRect(x: x, y: y, width: width, height: 30)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused
        _ = FixedFocusMotion.focusChange(context) { self.applyFocus(focused) }
    }

    /// (No lift: the window stays exactly where the picture is.)
    private func applyFocus(_ focused: Bool) {
        focusedNow = focused
        outline.alpha = focused ? 1 : 0
        shadow.alpha = focused ? 1 : 0
    }
}

/// A showcase row's card (New & Notable): tall, 4:5, three across, with
/// everything on it — at its foot, left-aligned over a shade, what's new
/// (a badge), the logo, the facts (no reason line: a badge's job). The picture: TMDB's poster with no
/// text, else the backdrop, cut to the card around the faces in it
/// (Vision). Focused: grown as every moving-focus card, outlined; after a
/// rest its trailer plays in it (`StageTrailer`, the controller's), cut to
/// the card, the words and shade fading out under it.
/// A Top 10's card is the same, small (`rankedCard`): its place in the
/// top-left corner over a soft shade, a smaller logo, a slim line (genre,
/// year), no badge and no trailer.
/// A large row's card (`feature`): a poster that opens into a wide card at
/// the spot (`setOpen`): both pictures pinned left at their own sizes, only
/// the card's width changing (a clip, nothing stretched), the poster fading
/// off the backdrop as it opens, back as it closes.
final class FixedFocusShowcaseCell: UICollectionViewCell, FixedFocusDestinationItem, TrailerHost {
    private(set) var itemIndex = 0
    private(set) weak var rowCell: FixedFocusRowCell?
    private(set) var item: MetaItem?
    private let card = UIView()
    /// What the card shows at its open size (a large row's: pictures, shade,
    /// words), from the card's left: the card's width only clips it.
    private let stage = UIView()
    private let picture = UIImageView()
    /// A large row's backdrop, over the poster while open.
    private let backdrop = UIImageView()
    private var backdropArt: String?
    private let shade = FixedFocusShade()
    private let edge = UIImageView()
    private let outline = UIView()
    /// The outline's shadow, sized with it in `sizeOutline` (in the same
    /// animation): following by autoresizing it was laid out later, in
    /// another spring, and the box's showed as a pale larger box shrinking.
    /// A plain layer's stretched contents, not an image view: the image
    /// view's own late layout animated its stretch in the next spring
    /// (200 pt too large, shrinking).
    private let outlineShadow: UIView = {
        let view = UIView()
        let image = FixedFocusCardEdge.shadowImage
        let caps = image.capInsets, size = image.size
        view.layer.contents = image.cgImage
        view.layer.contentsScale = image.scale
        view.layer.contentsCenter = CGRect(x: caps.left / size.width, y: caps.top / size.height,
                                           width: max(0, size.width - caps.left - caps.right) / size.width,
                                           height: max(0, size.height - caps.top - caps.bottom) / size.height)
        return view
    }()
    /// The words: they go while a trailer plays.
    private let words = UIView()
    /// The logo (or the name): lowered to the foot while its row is out of
    /// focus, the facts' room closed (`setDetailsShown`).
    private let title = UIView()
    private let badges = FixedFocusBadges()
    private let logo = FixedFocusLogo()
    private let name = UILabel()
    private let facts = UILabel()
    /// Today's Pick's description under the facts (the billboard's order),
    /// as many lines as the billboard's at most, the body level on the shade.
    /// Today's Pick: the tagline under the facts, as the billboard's (the
    /// name where there's none; the description was before).
    private let tagline = UILabel()
    /// The billboard's gap between its lines, frame to frame.
    private static let taglineGap: CGFloat = 5
    private let loadingCard = FixedFocusPlaceholder()
    /// A Top 10's place (nil elsewhere), and the shade behind it.
    private(set) var rank: Int?
    /// A large row's card: a poster, open where it is when focused.
    private(set) var feature = false
    /// Today's Pick: the content's width, on the backdrop, its description
    /// under the facts.
    private(set) var spotlight = false
    /// Its trailer after a rest: tall cards, and a large row's open card.
    var plays: Bool { rank == nil }
    private let place = UILabel()
    private let corner = UIImageView(image: FixedFocusShowcaseCell.cornerShade)
    private var art: String?
    private var extras: Task<Void, Never>?
    private var pressed = false
    private var held = false
    private var focusedNow = false
    private var trailerSurface: TrailerSurface?

    /// From the card's foot: the facts' line, the logo's room (smaller
    /// on a Top 10's card).
    private var footPad: CGFloat { plays ? 34 : 24 }
    private static let lineHeight: CGFloat = 30
    private var logoGap: CGFloat { plays ? 20 : 14 }
    private var logoBox: CGSize {
        plays ? CGSize(width: 400, height: 130) : CGSize(width: 240, height: 84)
    }
    private var sideInset: CGFloat { plays ? 32 : 28 - (rank == nil ? 0 : 4) }
    /// The place's corner: a soft dark from the top left, so the digits
    /// read on a bright picture.
    private static let cornerShade: UIImage = {
        let size = CGSize(width: 220, height: 180)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colours = [UIColor.black.withAlphaComponent(0.5).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours as CFArray,
                                            locations: [0, 1]) else { return }
            context.cgContext.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                                 endRadius: size.width, options: [])
        }
    }()
    /// Where the faces are across each backdrop (0–1), found once.
    private static var faces: [String: CGFloat] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        FixedFocusRing.follow(self)
        card.clipsToBounds = true
        card.layer.cornerRadius = Spotlight.cornerRadius
        card.layer.cornerCurve = .continuous
        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        contentView.addSubview(card)
        // All of it on the art (no caption): dark in both appearances.
        contentView.overrideUserInterfaceStyle = .dark
        card.addSubview(stage)
        // A large row's backdrop under the poster: opening, the poster fades
        // off it (the backdrop fading in over the card's grey left the grey
        // widening ahead of the picture).
        backdrop.contentMode = .scaleAspectFill
        backdrop.alpha = 0
        stage.addSubview(backdrop)
        picture.contentMode = .scaleAspectFill
        stage.addSubview(picture)
        loadingCard.isHidden = true
        loadingCard.layer.cornerRadius = 0
        stage.addSubview(loadingCard)
        stage.addSubview(shade)
        stage.addSubview(words)
        logo.contentMode = .scaleAspectFit
        logo.areaShare = 0.55
        name.font = .systemFont(ofSize: 40, weight: .semibold)
        name.textColor = CueInk.ui(FixedFocusText.primary)
        name.numberOfLines = 2
        facts.font = FixedFocusText.infoFont(FixedFocusMetrics.captionSize)
        facts.textColor = CueInk.ui(FixedFocusText.body)
        facts.lineBreakMode = .byTruncatingTail
        place.font = .systemFont(ofSize: 44, weight: .bold)
        place.textColor = CueInk.ui(FixedFocusText.primary)
        corner.contentMode = .topLeft
        tagline.font = UIFont.italicSystemFont(ofSize: FixedFocusMetrics.captionSize)
        tagline.textColor = CueInk.ui(FixedFocusText.secondary)
        tagline.lineBreakMode = .byTruncatingTail
        for view: UIView in [corner, place, badges, title, facts, tagline] { words.addSubview(view) }
        title.addSubview(logo)
        title.addSubview(name)
        logo.isHidden = true
        edge.isUserInteractionEnabled = false
        card.addSubview(edge)
        outline.isUserInteractionEnabled = false
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.alpha = 0
        contentView.addSubview(outline)
        outlineShadow.isUserInteractionEnabled = false
        outline.addSubview(outlineShadow)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: MetaItem, index: Int, rowCell: FixedFocusRowCell?, art poster: String?,
                   badges shown: [CardBadge], rank: Int? = nil, feature: Bool = false, spotlight: Bool = false) {
        self.spotlight = spotlight
        itemIndex = index
        self.rowCell = rowCell
        self.rank = rank
        let featureChanged = feature != self.feature
        self.feature = feature
        place.text = rank.map(String.init)
        place.isHidden = rank == nil
        corner.isHidden = rank == nil
        logo.areaShare = plays ? 0.55 : 0.5
        name.font = .systemFont(ofSize: plays ? 40 : 28, weight: .semibold)
        let changed = self.item?.id != item.id || featureChanged
        self.item = item
        shownBadges = shown
        showBadges(item)
        name.text = item.name
        tagline.text = spotlight ? TitleRecords.shared.tagline(item) ?? item.name : nil
        tagline.isHidden = !spotlight
        if changed {
            let art = spotlight ? poster ?? item.background ?? item.poster
                : poster ?? item.poster ?? item.background
            self.art = art
            backdrop.image = nil
            backdropArt = feature ? item.background ?? art : nil
            backdropWanted = false
            tintBadges(feature ? backdropArt : art)
            FixedFocusImages.load(art, into: picture,
                                  maxDimension: feature ? PictureSize.featurePoster : PictureSize.showcase,
                                  waiting: { [weak self] waiting in
                guard let self else { return }
                self.loadingCard.follow(waiting: waiting)
                self.edge.isHidden = waiting
                if !waiting { self.findFaces() }
                self.setNeedsLayout()
            })
            logo.image = nil
            logo.isHidden = true
            name.isHidden = false
            FixedFocusImages.load(item.logo, into: logo, maxDimension: PictureSize.cardLogo,
                                  waiting: { [weak self] waiting in
                guard let self, !waiting else { return }
                self.logo.isHidden = self.logo.image == nil
                self.name.isHidden = self.logo.image != nil
                self.setNeedsLayout()
            })
            parts = line(item)
            fitFacts()
            extras?.cancel()
            if rank == nil {
                extras = Task { @MainActor [weak self] in
                    guard await TitleRecords.shared.refresh(item, [.show, .facts]),
                          let self, !Task.isCancelled, self.item?.id == item.id else { return }
                    self.parts = self.line(item)
                    self.fitFacts()
                    self.showBadges(item)
                    self.setNeedsLayout()
                }
            }
        }
        // Out of a large row: its words and shade back.
        if !feature, featureChanged { setOpen(true) }
        applyFocus(isFocused)
        setNeedsLayout()
    }

    private var shownBadges: [CardBadge] = []
    private var tintTask: Task<Void, Never>?

    /// The plates' colour from the card's picture: at once if known, else
    /// faded in once sampled.
    private func tintBadges(_ url: String?) {
        tintTask?.cancel()
        guard let url else { badges.setTint(nil, animated: false); return }
        if let known = SourceTint.cached(for: url) { badges.setTint(known, animated: false); return }
        badges.setTint(nil, animated: false)
        tintTask = Task { @MainActor [weak self] in
            let tint = await SourceTint.tint(for: url)
            guard let self, !Task.isCancelled else { return }
            self.badges.setTint(tint, animated: true)
        }
    }

    /// The badges' line: a series' status first (not on a Top 10's card).
    private func showBadges(_ item: MetaItem) {
        badges.show(status: rank == nil ? FixedFocusShowInfo.status(item) : nil, shownBadges,
                    rating: rank == nil ? FixedFocusBadges.rating(item, sources: spotlight ? 3 : 1) : nil)
    }

    /// A large row's backdrop, loaded once it's near the spot (the open
    /// card and the next two): not for every poster in view.
    private var backdropWanted = false

    /// A large row's box for `poster` (the card under it, the same title):
    /// its poster, backdrop and logo taken as that card shows them, in from
    /// the first frame (loaded anew, one not in memory left an empty card
    /// for a few frames: a flicker).
    func adoptPictures(from poster: FixedFocusShowcaseCell) {
        guard poster.item?.id == item?.id else { return }
        if picture.image == nil, let image = poster.picture.image {
            FixedFocusImages.adopt(image, url: art, into: picture)
            loadingCard.follow(waiting: false)
            edge.isHidden = false
            findFaces()
        }
        if backdrop.image == nil, let image = poster.backdrop.image {
            FixedFocusImages.adopt(image, url: backdropArt, into: backdrop)
            backdropWanted = true
        }
        if logo.image == nil, let image = poster.logo.image {
            FixedFocusImages.adopt(image, url: item?.logo, into: logo)
            logo.isHidden = false
            name.isHidden = true
        }
        UIView.performWithoutAnimation {
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    func wantBackdrop() {
        guard feature, !backdropWanted, let backdropArt else { return }
        backdropWanted = true
        FixedFocusImages.load(backdropArt, into: backdrop, maxDimension: PictureSize.showcase,
                              waiting: { [weak self] waiting in
            guard let self, !waiting else { return }
            UIView.performWithoutAnimation { self.layoutPicture() }
            // In after the box opened: the poster fades off it.
            if self.open, self.picture.alpha > 0 { Self.fade(self.picture, to: 0, animated: true) }
        })
    }

    /// The facts line; a Top 10's slim one: its genre and year.
    /// The facts' parts. TMDB's paired TV genres cut short ("Action &
    /// Adventure": Action): the first half fits the card.
    private func line(_ item: MetaItem) -> [String] {
        func short(_ genre: String) -> String { genre.components(separatedBy: " & ")[0] }
        guard rank != nil else {
            let full = Set(item.genres ?? [])
            return FixedFocusShowInfo.factsLine(item).components(separatedBy: "  •  ")
                .map { full.contains($0) ? short($0) : $0 }
        }
        return [item.genres?.first.map(short), item.year].compactMap { $0 }
    }

    private var parts: [String] = []

    /// The parts that fit, whole, the last dropped first: never cut short.
    private func fitFacts() {
        let room = facts.bounds.width
        var shown = parts
        let attributes: [NSAttributedString.Key: Any] = [.font: facts.font as Any]
        while shown.count > 1, room > 0,
              (shown.joined(separator: "  •  ") as NSString).size(withAttributes: attributes).width > room {
            shown.removeLast()
        }
        let text = shown.joined(separator: "  •  ")
        if facts.text != text { facts.text = text }
    }

    /// The backdrop's faces, once per picture, off the main thread: the
    /// card is cut around them (none: its middle).
    private static let faceQueue = DispatchQueue(label: "cue.card-faces", qos: .utility)

    private func findFaces() {
        guard let art, Self.faces[art] == nil, let image = picture.image?.cgImage else { return }
        // Along the cut that fits it to the card: across a picture wider
        // than the card, down one narrower (Today's Pick's backdrop in its
        // wide card is cut down: it was cut across, by its faces' x).
        let size = feature ? FixedFocusFeatureLayout.poster : card.bounds.size
        let aspect = size.height > 0 ? size.width / size.height : 1
        // Vision blocks its thread: a queue of its own, not Swift's pool.
        Self.faceQueue.async {
            // No faces: a poster's upper middle, else the middle.
            let centre = TMDBService.faceCentre(image, aspect: aspect) ?? (image.height > image.width ? 0.4 : 0.5)
            DispatchQueue.main.async { [weak self] in
                Self.faces[art] = centre
                guard let self, self.art == art else { return }
                UIView.performWithoutAnimation { self.layoutPicture() }
            }
        }
    }

    /// A picture filling `size` from the top left, cut around its faces.
    private func fill(_ image: UIImage?, art: String?, in size: CGSize) -> CGRect {
        guard let image, image.size.height > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let aspect = image.size.width / image.size.height
        let centre = art.flatMap { Self.faces[$0] } ?? 0.5
        if aspect <= size.width / size.height {
            // A poster: the width, cut down its height.
            let height = size.width / aspect
            let y = min(0, max(size.height - height, size.height / 2 - centre * height))
            return CGRect(x: 0, y: y, width: size.width, height: height)
        }
        // A backdrop: the height, cut across.
        let width = size.height * aspect
        let x = min(0, max(size.width - width, size.width / 2 - centre * width))
        return CGRect(x: x, y: 0, width: width, height: size.height)
    }

    /// The card on screen as it looks now (grown): where a trailer handed
    /// into Details grows from.
    var screenCard: CGRect { mirror?.screenCard ?? card.convert(card.bounds, to: nil) }
    /// Today's Pick as Back from Details shrinks into it: the card and its
    /// picture on the screen (as Home's billboard card's `openingWindow`).
    func backWindow() -> DetailTransition.Window? {
        guard spotlight, window != nil else { return nil }
        return DetailTransition.Window(card: card.convert(card.bounds, to: nil),
                                       picture: picture.convert(picture.bounds, to: nil),
                                       screen: card.convert(card.bounds, to: nil))
    }

    private func layoutPicture() {
        if feature {
            // Each at its own size from the left: the card's width only clips.
            picture.frame = fill(picture.image, art: art, in: FixedFocusFeatureLayout.poster)
            backdrop.frame = fill(backdrop.image, art: nil, in: FixedFocusFeatureLayout.large)
            trailerSurface?.frame = CGRect(origin: .zero, size: FixedFocusFeatureLayout.large)
        } else {
            picture.frame = fill(picture.image, art: art, in: card.bounds.size)
            trailerSurface?.frame = card.bounds
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre: they may be grown (transformed).
        card.bounds = CGRect(origin: .zero, size: bounds.size)
        card.center = CGPoint(x: bounds.midX, y: bounds.midY)
        outline.center = card.center
        outline.layer.borderWidth = FixedFocusRing.width
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        // A large row's stage at the open size, from the left: the card's
        // width clips it, nothing moves inside it.
        let face = feature ? FixedFocusFeatureLayout.large : bounds.size
        stage.frame = CGRect(origin: .zero, size: face)
        layoutPicture()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = CGRect(origin: .zero, size: face)
        CATransaction.commit()
        edge.image = FixedFocusCardEdge.rim
        edge.frame = card.bounds
        loadingCard.frame = feature ? CGRect(origin: .zero, size: FixedFocusFeatureLayout.poster) : card.bounds
        words.frame = CGRect(origin: .zero, size: face)
        // (Bounds and centre: it may be lowered, transformed.)
        title.bounds = CGRect(origin: .zero, size: face)
        title.center = CGPoint(x: face.width / 2, y: face.height / 2)
        // From the foot up: the facts, the logo (or the name); the badges top left.
        corner.frame = CGRect(origin: .zero, size: Self.cornerShade.size)
        place.sizeToFit()
        place.frame.origin = CGPoint(x: sideInset, y: 14)
        let sideInset = self.sideInset, logoBox = self.logoBox
        let width = face.width - 2 * sideInset
        // The badges top left, the symbols in line with the logo's left, the
        // plates as far from the top as from the side.
        let plateInset = sideInset - FixedFocusBadges.padding
        badges.frame = CGRect(x: plateInset, y: plateInset, width: face.width - 2 * plateInset,
                              height: FixedFocusBadges.wrappedHeight)
        var foot = face.height - footPad
        if spotlight {
            tagline.frame = CGRect(x: sideInset, y: foot - Self.lineHeight, width: width, height: Self.lineHeight)
            foot = tagline.frame.minY - Self.taglineGap
        }
        let y = foot - Self.lineHeight
        facts.frame = CGRect(x: sideInset, y: y, width: width, height: Self.lineHeight)
        fitFacts()
        let titleBottom = y - logoGap + 6
        // Out of focus, the logo's foot where the facts' baseline is.
        titleDrop = face.height - footPad - Self.lowFoot - titleBottom
        UIView.performWithoutAnimation {
            title.transform = detailsShown ? .identity : CGAffineTransform(translationX: 0, y: titleDrop)
        }
        if !logo.isHidden, logo.image != nil {
            // Sized by its area, its foot on the line, at the left.
            logo.room = CGRect(x: sideInset, y: titleBottom - logoBox.height,
                               width: logoBox.width, height: logoBox.height)
        } else {
            let fitted = name.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            name.frame = CGRect(x: sideInset, y: titleBottom - fitted, width: width, height: fitted)
        }
        sizeOutline()
    }

    // MARK: Its row in focus or not

    /// Badges, rating, facts and tagline only while its row has focus; the
    /// logo lowered into their room while it hasn't, all in the rows' move.
    private(set) var detailsShown = true
    private var titleDrop: CGFloat = 0
    /// The lowered logo's foot above the card's text foot.
    private static let lowFoot: CGFloat = 6
    /// The logo's rise and settle (the rows' move is 0.5 s).
    private static let titleMove: Double = 0.35

    func setDetailsShown(_ shown: Bool, animated: Bool) {
        guard shown != detailsShown else { return }
        detailsShown = shown
        let texts: [UIView] = [badges, facts, tagline]
        let lowered = CGAffineTransform(translationX: 0, y: titleDrop)
        // The text in the rows' move (its spring), as the captions. The
        // logo on a shorter spring of its own: on the rows' 0.5 s its
        // movement went on after the fade read as done.
        let from = title.layer.presentation()?.transform ?? title.layer.transform
        UIView.performWithoutAnimation { title.transform = shown ? .identity : lowered }
        if animated, window != nil {
            let move = CASpringAnimation(perceptualDuration: Self.titleMove, bounce: 0)
            move.keyPath = "transform"
            move.fromValue = from
            move.toValue = title.layer.transform
            move.duration = move.settlingDuration
            title.layer.add(move, forKey: "transform")
        } else {
            title.layer.removeAnimation(forKey: "transform")
        }
        FixedFocusDetails.fade(texts, shown: shown, animated: animated)
    }

    // MARK: The trailer

    func attachTrailer(_ surface: TrailerSurface) {
        if let mirror { return mirror.attachTrailer(surface) }
        trailerSurface = surface
        guard surface.superview !== stage else { return }
        stage.insertSubview(surface, aboveSubview: picture)
        layoutPicture()
    }

    // MARK: Focus

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused || (HoldMenu.shared.isOpen && context.previouslyFocusedView === self)
        // Under the box, focus going to the next card in the row: the box
        // stays as it is (the row hands it the next title); eased back here
        // it shrank under the new one.
        if mirror != nil, !focused, passesFocusAlong(context) {
            focusedNow = false
            pressed = false
            return
        }
        _ = FixedFocusMotion.focusChange(context) { self.applyFocus(focused) }
    }

    /// Focused, grown. Wider cards (a large row's open card, Today's Pick)
    /// grow, press and hold by the tall cards' points, not their share
    /// (6 % of a wide card's width was far more than theirs).
    private var cardSize: CGSize {
        spotlight ? FixedFocusMetrics.spotlightCard : feature ? FixedFocusMetrics.featureCard
            : rank != nil ? FixedFocusMetrics.rankedCard : FixedFocusMetrics.showcaseCard
    }
    private var lift: CGFloat { FixedFocusMetrics.focusLift(cardSize) }
    private var pressDrop: CGFloat { FixedFocusMetrics.pressDrop(cardSize) }

    private var scale: CGFloat {
        guard focusedNow else { return 1 }
        return 1 + lift - (pressed ? pressDrop : 0)
            + (held ? FixedFocusMetrics.heldGrowth(cardSize) : 0)
    }

    /// The outline and its shadow scaled with the card, by the same
    /// transform: sized to the grown card instead, while the box grew out
    /// of a poster with its focus (size and scale changing together) they
    /// ran a few points ahead of the picture, the page showing pale
    /// between the card and the shadow's edge. (The line grows with it,
    /// 2 pt to about 2.1.)
    private func sizeOutline() {
        outline.bounds = CGRect(origin: .zero, size: bounds.size)
        outline.transform = CGAffineTransform(scaleX: scale, y: scale)
        outline.layer.cornerRadius = Spotlight.cornerRadius
        let pad = FixedFocusCardEdge.shadowPad
        outlineShadow.frame = outline.bounds.insetBy(dx: -pad, dy: -pad)
    }

    private func applyFocus(_ focused: Bool) {
        focusedNow = focused
        if !focused, !held { pressed = false }
        if let mirror {
            card.transform = .identity
            outline.alpha = 0
            mirror.reflect(focused: focused, pressed: pressed, held: held)
            return
        }
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        sizeOutline()
        outline.alpha = focused ? 1 : 0
        if focused { superview?.bringSubviewToFront(self) }
    }

    // MARK: Under the box

    /// Focus going from this card to another of its row.
    private func passesFocusAlong(_ context: UIFocusUpdateContext) -> Bool {
        guard let next = context.nextFocusedView as? FixedFocusShowcaseCell else { return false }
        return next.superview === superview
    }

    /// The box's new title: its picture and words fading in over the old
    /// box, the outline and shadow there at once.
    func dissolveIn(then done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        defer { CATransaction.commit() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        card.layer.add(fade, forKey: "dissolve")
    }

    /// The box going out under a new one: its outline and shadow gone at
    /// once (the new one's are there).
    func dropOutline() {
        UIView.performWithoutAnimation { outline.alpha = 0 }
    }

    /// Showing focus (grown, outlined).
    var isFocusedLook: Bool { focusedNow }



    /// A large row's card under the box (`FixedFocusRowCell`'s open card at
    /// the spot): it keeps focus, press and hold; the box shows them and
    /// plays its trailer.
    weak var mirror: FixedFocusShowcaseCell? {
        didSet { if mirror !== oldValue { applyFocus(focusedNow) } }
    }
    /// Its picture hidden once it's under the box (sliding in, it shows).
    var hiddenUnderBox = false {
        didSet { card.isHidden = hiddenUnderBox }
    }

    /// The box showing the focus, press and hold of the card under it.
    func reflect(focused: Bool, pressed: Bool, held: Bool) {
        // Nothing new (the card under it taking focus as the box arrives):
        // applied again in its spring, the outline would move.
        guard focused != focusedNow || pressed != self.pressed || held != self.held else { return }
        self.pressed = pressed
        self.held = held
        applyFocus(focused)
    }

    func setHeld(_ held: Bool) {
        guard held != self.held else { return }
        self.held = held
        if !held { pressed = false }
        UIView.animate(withDuration: FixedFocusMetrics.heldDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.applyFocus(self.focusedNow)
        }
    }

    /// A large row's card open (the backdrop and words, the poster gone:
    /// the row's box) or a poster (the cards under it). Set at once: the
    /// box is open from the moment it's made.
    private var open = true

    func setOpen(_ open: Bool) {
        self.open = open
        if open { wantBackdrop() }
        let opened = feature && open
        for view in [words, shade] as [UIView] { Self.fade(view, to: open ? 1 : 0, animated: false) }
        Self.fade(backdrop, to: opened ? 1 : 0, animated: false)
        Self.fade(picture, to: opened && backdrop.image != nil ? 0 : 1, animated: false)
    }

    /// `view` to `alpha`, faded (from where it is) or at once.
    private static func fade(_ view: UIView, to alpha: CGFloat, animated: Bool) {
        let from = view.layer.presentation()?.opacity ?? Float(view.alpha)
        view.layer.removeAnimation(forKey: "open")
        UIView.performWithoutAnimation { view.alpha = alpha }
        guard animated, abs(from - Float(alpha)) > 0.01 else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = Float(alpha)
        animation.duration = Motion.fadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer.add(animation, forKey: "open")
    }

    private func setPressed(_ pressed: Bool) {
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
        // A hold cancels the press just before the menu holds the card: it
        // grows on to its held size, as the dim's hole around it.
        if presses.contains(where: { $0.type == .select }) { setPressed(false) }
        super.pressesCancelled(presses, with: event)
    }

    /// Its hold menu (`HoldMenu`): beside the card at its held size.
    func holdMenu(_ entries: [MenuEntry]) -> HoldMenuRequest {
        if let mirror {
            var request = mirror.holdMenu(entries)
            request.onHeld = { [weak self] in self?.setHeld($0) }
            return request
        }
        let lift = self.lift
        func sized(_ scale: CGFloat) -> CGRect {
            convert(bounds.insetBy(dx: -bounds.width * (scale - 1) / 2, dy: -bounds.height * (scale - 1) / 2), to: nil)
        }
        let now = 1 + lift - (pressed ? pressDrop : 0)
        let heldScale = 1 + lift + FixedFocusMetrics.heldGrowth(cardSize)
        return HoldMenuRequest(entries: entries, anchor: sized(heldScale),
                               from: sized(now), rest: sized(1 + lift),
                               onHeld: { [weak self] in self?.setHeld($0) },
                               // Today's Pick has no side: over its right.
                               inside: spotlight ? sideInset : nil)
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
        HStack(spacing: RatingChip.spacing) {
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
enum ContinueMenuAction {
    case details, startOver, chooseSource, markWatched, remove

    /// `series`: the card is an episode, so Details is the show's.
    func title(series: Bool) -> String {
        switch self {
        case .details: return series ? "Go to Show" : "Go to Movie"
        case .startOver: return "Start Over"
        case .chooseSource: return "Choose Source"
        case .markWatched: return series ? "Mark Episode as Watched" : "Mark as Watched"
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
    /// A grid's portraits: the name and role on the card, at its foot over
    /// the cards' bottom fade, as a tall card's words (under it, two lines
    /// of portraits left the rows above and below no peek).
    private let onCardShade = FixedFocusShade()
    private let onCardText = UIView()
    private let onCardName = UILabel()
    private let onCardDetail = UILabel()
    private var captionOnCard = false
    /// Focused: the name and role in full, wrapping upward from the foot
    /// (two lines each at most: a wrapped name left the role cut at
    /// three); at rest a line each, a long one fading out
    /// at its end (no "…"). Crossfaded (`onCardFade`) as the card grows.
    private var onCardFull = false
    private static let onCardFade = 0.25
    private static let onCardLines = 2
    /// A cut line's end fading into the card.
    private static let fadeRun: CGFloat = 36
    /// A logo row's logo: one colour, the page's ink, on the flat grey of
    /// the page's controls (light plates glared in dark; the brands'
    /// colours on them looked a jumble).
    private let logo = UIImageView()
    static let logoInset = CGSize(width: 34, height: 30)
    /// Most of the logo's picture opaque: drawn on a box of its own.
    static func boxed(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let side = 24
        var alpha = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &alpha, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Double(alpha.filter { $0 > 200 }.count) / Double(alpha.count) > 0.7
    }
    /// A logo with a colour of its own: a sixth of its drawn pixels
    /// clearly coloured (saturated, not dark).
    static func colourful(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var drawn = 0, coloured = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3])
            guard a > 128 else { continue }
            drawn += 1
            let rgb = (0..<3).map { Double(pixels[i + $0]) / a }
            let high = rgb.max() ?? 0, low = rgb.min() ?? 0
            if high > 0.25, (high - low) / max(high, 0.001) > 0.35 { coloured += 1 }
        }
        return drawn > 0 && Double(coloured) / Double(drawn) > 1.0 / 6
    }
    /// `FlatControl.rest`, in UIKit.
    static let logoPlate = UIColor { $0.userInterfaceStyle == .light
        ? UIColor.white.withAlphaComponent(0.32) : UIColor.white.withAlphaComponent(0.13) }

    /// The plates on a landscape card (episode, time left, day) only in
    /// the focused row (`FixedFocusDetails`).
    func setDetailsShown(_ shown: Bool, animated: Bool) {
        state.setPlatesShown(shown, animated: animated)
    }

    /// The name and second line under the card (its row focused).
    func setCaptionShown(_ shown: Bool) {
        name.alpha = shown ? 1 : 0
        detail.alpha = shown ? 1 : 0
        nameBar.alpha = name.alpha
        detailBar.alpha = detail.alpha
    }

    /// A landscape card's state (episode and time left on plates, the bar),
    /// the picture's lower half darkened under the bar only.
    private let state = FixedFocusProgressView()
    private let stateShade = CAGradientLayer()
    private var tintTask: Task<Void, Never>?
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
        contentView.addSubview(picture)
        // The art and its plates dark in both appearances; the caption
        // under it follows tvOS's (`CueInk`).
        picture.overrideUserInterfaceStyle = .dark
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
        onCardShade.isHidden = true
        picture.insertSubview(onCardShade, belowSubview: edge)
        onCardText.isUserInteractionEnabled = false
        picture.insertSubview(onCardText, belowSubview: edge)
        onCardName.font = FixedFocusText.titleFont(FixedFocusMetrics.captionSize)
        onCardName.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        onCardDetail.font = FixedFocusText.infoFont(FixedFocusMetrics.captionSize)
        onCardDetail.textColor = UIColor.white.withAlphaComponent(FixedFocusText.body)
        for label in [onCardName, onCardDetail] {
            label.isHidden = true
            onCardText.addSubview(label)
        }
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
        detail.textColor = CueInk.ui(FixedFocusText.infoLevel(focused: false))
        for label in [name, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
        }
        // Below the picture's FOCUSED frame: a lift pushes them down.
        captionGap = name.topAnchor.constraint(equalTo: picture.focusedFrameGuide.bottomAnchor,
                                               constant: FixedFocusMetrics.infoGap)
        NSLayoutConstraint.activate([
            captionGap,
            name.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FixedFocusMetrics.textIndent),
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
        edge.image = Self.lift ? nil : FixedFocusCardEdge.rim
        edge.frame = picture.bounds
        loadingCard.frame = picture.bounds
        placeholderCard.frame = card
        placeholderCard.isHidden = !isPlaceholder
        nameBar.isHidden = !isPlaceholder
        detailBar.isHidden = !isPlaceholder
        picture.isHidden = isPlaceholder
        // (Room round it in proportion: a wide logo stays a band across a
        // square, never a block.)
        let room = picture.bounds.size
        logo.frame = picture.bounds.insetBy(dx: max(Self.logoInset.width, room.width * 0.16),
                                            dy: max(Self.logoInset.height, room.height * 0.3))
        if captionOnCard { layoutOnCard() }
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

    /// The name and role on the card: from the foot up, the role's lines,
    /// then the name's.
    private func layoutOnCard() {
        onCardShade.frame = picture.bounds
        onCardText.frame = picture.bounds
        let inset = FixedFocusMetrics.textIndent + 8
        let width = picture.bounds.width - 2 * inset
        let step = FixedFocusMetrics.captionLineOffset
        let wrap = onCardName.font.lineHeight.rounded()
        let hasDetail = !onCardDetail.isHidden
        func lines(_ label: UILabel) -> Int {
            let text = (label.text ?? "") as NSString
            let height = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                           options: .usesLineFragmentOrigin,
                                           attributes: [.font: label.font as Any], context: nil).height
            return max(1, Int((height / label.font.lineHeight).rounded(.up)))
        }
        var nameLines = 1, detailLines = hasDetail ? 1 : 0
        if onCardFull {
            let name = lines(onCardName), detail = hasDetail ? lines(onCardDetail) : 0
            detailLines = min(detail, Self.onCardLines)
            nameLines = min(name, Self.onCardLines)
        }
        let foot = picture.bounds.height - 18
        var top = foot - 30
        if hasDetail {
            top -= CGFloat(detailLines - 1) * wrap
            onCardDetail.frame = CGRect(x: inset, y: top, width: width, height: 30 + CGFloat(detailLines - 1) * wrap)
            top -= step
        }
        top -= CGFloat(nameLines - 1) * wrap
        onCardName.frame = CGRect(x: inset, y: top, width: width, height: 30 + CGFloat(nameLines - 1) * wrap)
        for (label, count) in [(onCardName, nameLines), (onCardDetail, detailLines)] {
            label.numberOfLines = count
            label.lineBreakMode = onCardFull ? .byTruncatingTail : .byClipping
            // At rest, a line too long fades out at its end.
            let cut = !onCardFull && lines(label) > 1
            if cut {
                let mask = (label.layer.mask as? CAGradientLayer) ?? CAGradientLayer()
                mask.frame = label.bounds
                mask.startPoint = CGPoint(x: 0, y: 0.5)
                mask.endPoint = CGPoint(x: 1, y: 0.5)
                mask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
                mask.locations = [0, NSNumber(value: Double(1 - Self.fadeRun / max(width, 1))), 1]
                label.layer.mask = mask
            } else {
                label.layer.mask = nil
            }
        }
    }

    /// Focus on and off: the text in full or a line each, crossfaded.
    private func setOnCardFull(_ full: Bool, animated: Bool) {
        guard captionOnCard, full != onCardFull else { return }
        let change = {
            self.onCardFull = full
            self.layoutOnCard()
        }
        guard animated else { change(); return }
        UIView.transition(with: onCardText, duration: Self.onCardFade,
                          options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction],
                          animations: change)
    }

    /// The card itself, without its caption (in the cell).
    var cardFrame: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: cardHeight) }

    /// Its hold menu (`HoldMenu`): beside the card at its held size —
    /// lifted and a little grown — without its caption.
    func holdMenu(_ entries: [MenuEntry]) -> HoldMenuRequest {
        let card = cardFrame
        let lift = FixedFocusMetrics.focusLift(card.size)
        let scale = lift > 0 && !Self.lift ? 1 + lift + FixedFocusMetrics.heldGrowth(card.size) : 1
        func sized(_ scale: CGFloat) -> CGRect {
            convert(card.insetBy(dx: -card.width * (scale - 1) / 2, dy: -card.height * (scale - 1) / 2), to: nil)
        }
        let now = scale == 1 ? 1 : 1 + lift - (pressed ? FixedFocusMetrics.pressDrop(card.size) : 0)
        return HoldMenuRequest(entries: entries, anchor: sized(scale), from: sized(now),
                               rest: sized(scale == 1 ? 1 : 1 + lift),
                               onHeld: { [weak self] in self?.setHeld($0) })
    }

    /// The plates' colour from the card's picture: at once if known, else
    /// faded in once sampled.
    private func tintState(_ url: String?) {
        tintTask?.cancel()
        guard let url else { state.setTint(nil, animated: false); return }
        if let known = SourceTint.cached(for: url) { state.setTint(known, animated: false); return }
        state.setTint(nil, animated: false)
        tintTask = Task { @MainActor [weak self] in
            let tint = await SourceTint.tint(for: url)
            guard let self, !Task.isCancelled else { return }
            self.state.setTint(tint, animated: true)
        }
    }

    /// New progress for the title it already shows.
    func showProgress(_ progress: WatchProgress) {
        detail.text = progress.episodeTitle ?? detail.text
        state.show(progress)
        stateShade.isHidden = !state.hasBar
    }

    func configure(_ item: MetaItem, subtitle: String?, index: Int, rowCell: FixedFocusRowCell?, card: CGSize,
                   progress: WatchProgress? = nil, cardState: FixedFocusCardState? = nil,
                   art override: String? = nil, isLogo: Bool = false, captionOnCard: Bool = false) {
        itemIndex = index
        self.captionOnCard = captionOnCard
        onCardName.text = item.name
        onCardDetail.text = subtitle
        for view in [onCardShade, onCardName] as [UIView] { view.isHidden = !captionOnCard }
        onCardDetail.isHidden = !captionOnCard || subtitle?.isEmpty != false
        name.isHidden = captionOnCard
        detail.isHidden = captionOnCard
        onCardFull = captionOnCard && isFocused
        self.rowCell = rowCell
        cardHeight = card.height
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
        stateShade.isHidden = !hasState || !state.hasBar
        setNeedsLayout()
        let art = override ?? (card.width > card.height ? (item.background ?? item.poster) : (item.poster ?? item.background))
        if hasState { tintState(art) }
        let blurred = cardState?.blurred == true
        let key = "\(item.id)|\(art ?? "")|\(Int(card.width))|\(blurred)"
        guard key != shown else { return }
        shown = key
        // A logo: on the page's grey, in its ink, fitted with room around it.
        logo.isHidden = !isLogo
        // (The art dark in both appearances; a logo's plate is the page's.)
        picture.overrideUserInterfaceStyle = isLogo ? .unspecified : .dark
        if isLogo {
            // (Drops a reused card's poster still on its way — it landed
            // over the logo's plate.)
            FixedFocusImages.load(nil, into: picture, maxDimension: 0)
            logo.image = nil
            logo.tintColor = CueInk.ui(FixedFocusText.primary)
            FixedFocusImages.load(art, into: logo, maxDimension: PictureSize.landscape,
                                  waiting: { [weak self] waiting in
                guard let self else { return }
                // (A logo drawn on a box of its own keeps its colours: in
                // one colour it went a solid bar. So does one with a clear
                // colour of its own — Netflix's red; black, white and grey
                // ones are drawn in the ink, readable in both appearances.)
                if !waiting, let image = self.logo.image, !Self.boxed(image), !Self.colourful(image) {
                    self.logo.image = image.withRenderingMode(.alwaysTemplate)
                }
                self.pictureWaiting(waiting, plate: true)
            })
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
        picture.backgroundColor = plate && !waiting ? Self.logoPlate : nil
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        // Focus into a hold menu (`HoldMenu`): the card stays lifted.
        let focused = isFocused || (HoldMenu.shared.isOpen && context.previouslyFocusedView === self)
        guard !Self.lift else {
            coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
            return
        }
        // On Home's curve and timing, with the row's scroll.
        let animated = FixedFocusMotion.focusChange(context) {
            self.applyFocus(focused)
            self.layoutIfNeeded()
        }
        // (Its own timing: outside the move's spring.)
        setOnCardFull(focused, animated: animated)
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
        name.textColor = CueInk.ui(FixedFocusText.titleLevel(focused: focused))
        detail.textColor = CueInk.ui(FixedFocusText.infoLevel(focused: focused))
        guard !Self.lift else { return }
        // Grown and outlined — the captions step down with it.
        let size = cardFrame.size
        let lift = FixedFocusMetrics.focusLift(size)
        let grows = lift > 0
        // Pressed: a little less lifted; held: a little more.
        let scale = focused && grows
            ? 1 + lift - (pressed ? FixedFocusMetrics.pressDrop(size) : 0)
                + (held ? FixedFocusMetrics.heldGrowth(size) : 0)
            : 1
        let grown = CGAffineTransform(scaleX: scale, y: scale)
        picture.transform = grown
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

/// The billboard's focus targets: one per title, nothing drawn (the
/// billboard's picture and text show the focused one).
final class FixedFocusPosterCell: UICollectionViewCell {
    private(set) var itemIndex = 0
    private(set) weak var rowCell: FixedFocusRowCell?

    func configure(index: Int, rowCell: FixedFocusRowCell) {
        itemIndex = index
        self.rowCell = rowCell
        contentView.isHidden = true
    }
}

/// The billboard's strip: title i at `inset + i × pitch`.
final class FixedFocusStripLayout: UICollectionViewLayout {
    /// The row extends this far beyond the screen on both sides; positions
    /// are shifted by it (so on screen nothing moves).
    static let overscan: CGFloat = 1200
    /// The cards' width (posters; landscape: box-wide) and height.
    var cardWidth: () -> CGFloat = { FixedFocusMetrics.posterWidth }
    var cardHeight: () -> CGFloat = { FixedFocusMetrics.height }
    private var frames: [CGRect] = []
    private var contentWidth: CGFloat = 0
    private var height = FixedFocusMetrics.height

    override func prepare() {
        super.prepare()
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let card = cardWidth()
        height = cardHeight()
        let pitch = card + FixedFocusMetrics.gap
        frames = (0..<count).map { i in
            CGRect(x: Self.overscan + FixedFocusMetrics.inset + CGFloat(i) * pitch, y: 0,
                   width: card, height: height)
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
    /// Centred rows: how much lower than the usual spot row `r` stands in
    /// focus (nil: at the spot).
    var centredDrop: (Int) -> CGFloat? = { _ in nil }
    /// See `FixedFocusRows.rigidRest`.
    var rigidRest: () -> CGFloat? = { nil }
    /// The billboard's own distance up at a depth, if it has one.
    var billboardUp: (Int) -> CGFloat? = { _ in nil }
    /// Every row's top with row `f` focused, as the last `prepare` laid
    /// them out (the billboard follows the row under it: `rowTop(_:focus:)`).
    private var topsFor: ((Int) -> [CGFloat])?
    func rowTop(_ r: Int, focus f: Int) -> CGFloat? {
        guard let tops = topsFor?(f), tops.indices.contains(r) else { return nil }
        return tops[r]
    }
    /// A row's cards' height (one size, but for a side-info row).
    var cardHeight: (Int) -> CGFloat = { _ in FixedFocusMetrics.height }
    /// A row's cards this much lower under its name (a line under it).
    var titleExtra: (Int) -> CGFloat = { _ in 0 }
    /// How much of the rows above and below shows.
    var peeks: () -> (above: CGFloat, below: CGFloat) = {
        (FixedFocusMetrics.aboveVisible, FixedFocusMetrics.belowVisible)
    }
    /// How much of a row's height is below its cards (a destination row's
    /// captions): the row above shows its CARDS' lower part, as any row.
    var belowCards: (Int) -> CGFloat = { _ in 0 }
    /// How far a focused row draws, from its anchor (its name; a panel's
    /// top) to the end of what shows under its cards (the fixed box's info,
    /// captions, a panel's edge): the next row's name the peek gap below it.
    var drawnHeight: (Int) -> CGFloat = { _ in
        FixedFocusMetrics.titleHeight + FixedFocusMetrics.height
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
        /// The lowest the row below the focused one may start: its name and
        /// the minimum peek of its cards still on the screen.
        let lowestBelow = screen - FixedFocusMetrics.titleHeight - Self.minimumPeek
        /// Every row's top with row `f` focused: the focused one at the spot;
        /// the next the same gap below the end of what the focused one draws
        /// (whatever its height — so the peek varies, the gap doesn't), but
        /// never lower than its minimum peek; the ones after it the same gap
        /// apart; the one before peeking down from the top, the rest a row
        /// apart above it.
        func tops(_ f: Int) -> [CGFloat] {
            var y = [CGFloat](repeating: 0, count: count)
            guard count > 0 else { return y }
            let f = min(max(f, 0), count - 1)
            let centred = centredDrop(f)
            let focusY = centred.map { focusY - rowDrop() + $0 } ?? focusY
            let gap = centred == nil ? FixedFocusMetrics.peekGap : FixedFocusMetrics.centredGap
            y[f] = focusY
            if f + 1 < count {
                let after = focusY + drawnHeight(f) + gap
                y[f + 1] = (centred == nil ? min(after, lowestBelow) : after)
            }
            // Further down: the same gap below each row (its height, captions
            // in) — a row coming up to be next doesn't move again.
            if f + 2 < count {
                for r in (f + 2)..<count {
                    y[r] = y[r - 1] + heights[r - 1] + gap
                }
            }
            if f > 0, centred != nil {
                // Centred: the row above the same gap over it as the one below.
                y[f - 1] = y[f] - gap - heights[f - 1] + belowCards(f - 1)
            } else if f > 0 {
                y[f - 1] = peek.above - heights[f - 1] + belowCards(f - 1)
            }
            // Further up: the same gap above each row, below the cards of the
            // one over it (out of focus, its captions don't show).
            if f > 1 {
                for r in stride(from: f - 2, through: 0, by: -1) {
                    y[r] = y[r + 1] - gap - heights[r] + belowCards(r)
                }
            }
            return y
        }
        topsFor = tops
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
                    y = normal(r, next) + rest - focusY - (centredDrop(next) ?? 0)
                } else if belowAway() {
                    y = normal(r, next) + Self.billboardScroll(depth: 1)
                } else {
                    let cardsTop = screen - Self.restingCardsOnScreen
                    y = normal(r, next) + cardsTop - FixedFocusMetrics.titleHeight - focusY
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

enum FixedFocusDetails {
    static func fade(_ views: [UIView], shown: Bool, animated: Bool) {
        let apply = { for view in views { view.alpha = shown ? 1 : 0 } }
        if animated { apply() } else { UIView.performWithoutAnimation(apply) }
    }
}

final class FixedFocusProgressView: UIView {
    private let plates = FixedFocusBadges()
    private let barShadow = UIView()
    private let track = UIView()
    private let fill = UIView()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(plates)
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

    /// The plates only while the row has focus (the bar stays: where you
    /// are reads at a glance, as the logo).
    private var platesShown = true
    func setPlatesShown(_ shown: Bool, animated: Bool) {
        guard shown != platesShown else { return }
        platesShown = shown
        FixedFocusDetails.fade([plates], shown: shown, animated: animated)
    }

    /// A state given as such (Details' episodes): the label and the text,
    /// a bar (in progress) or nothing.
    func show(_ state: FixedFocusCardState) {
        showPlates(state.label, state.right, symbol: state.rightSymbol)
        fraction = CGFloat(state.fraction ?? 0)
        track.isHidden = state.fraction == nil
        setNeedsLayout()
    }

    func show(_ entry: WatchProgress?) {
        guard let entry else { return }
        // Continue Watching: "S1:E5" (its title in the caption under the card).
        let started = entry.isStarted
        showPlates(entry.season.flatMap { s in entry.episode.map { "S\(s):E\($0)" } },
                   started ? (entry.remainingTimeText.map { "\($0) left" } ?? "In progress") : "Up Next")
        fraction = started ? CGFloat(entry.fraction) : 0
        track.isHidden = !started
        setNeedsLayout()
    }

    /// Whether the bar shows (the cell darkens the foot under it only then).
    var hasBar: Bool { !track.isHidden }

    /// The plates' colour: the card's picture's (`SourceTint`).
    func setTint(_ tint: UIColor?, animated: Bool) { plates.setTint(tint, animated: animated) }

    private func showPlates(_ episode: String?, _ state: String?, symbol: FixedFocusBadges.Symbol? = nil) {
        plates.show(episode.map { [FixedFocusBadges.Badge(text: $0)] } ?? [],
                    rating: state.map { FixedFocusBadges.Badge(symbol: symbol, text: $0) })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Spotlight.stateInset
        let width = bounds.width - inset * 2
        let barH = Spotlight.stateBarHeight
        let barTop = bounds.height - inset - barH
        // The words in line with the bar's ends, the plates as far from the
        // top as from the side.
        let plateInset = inset - FixedFocusBadges.padding
        plates.frame = CGRect(x: plateInset, y: plateInset, width: bounds.width - 2 * plateInset,
                              height: FixedFocusBadges.height)
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
    /// A card's focus coming or going: on the move's spring, but at once
    /// under a page's fade when no press moved it (focus leaving as a
    /// page goes in, coming back on Back): the page's still shows the card
    /// as it was, and the live one growing or shrinking under it read as
    /// a grow and a shrink, flickering.
    static func focusChange(_ context: UIFocusUpdateContext, _ animations: @escaping () -> Void) -> Bool {
        if PageFade.shared.busy, context.focusHeading.isEmpty {
            UIView.performWithoutAnimation(animations)
            return false
        }
        run(duration: Motion.moveDuration, animations: animations) { _ in }
        return true
    }

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

    /// Between the billboard and the rows: a row step's own length (Home's
    /// card scrolls as a row; 0.6, a little longer for the longer way,
    /// felt slow).
    static let billboardScroll: Double = Motion.verticalDuration

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

/// A card's badges (`HomeRow.badges(for:)`), top left, a series' status
/// first: a two-tone symbol and the words on a dark plate, Netflix's
/// (Apple TV's plates over the logo, with a bright edge, read as stickers;
/// one line of capitals with no plate was too plain; small capitals on
/// black 45 % were hard to read at times).
final class FixedFocusBadges: UIView {
    static let font = UIFont.systemFont(ofSize: 23, weight: .semibold)
    static let height: CGFloat = 40
    /// The words' indent in their plate (the symbol's, when there is one).
    static let padding: CGFloat = 12
    static let gap: CGFloat = 8
    private var plates: [Plate] = []
    private var shown: [Badge] = []
    private let ratingPlate = Plate()
    private var rating: Badge?

    /// The symbols, Netflix's way: grey, some with one part in Cue's colour, the
    /// app icon's red (its top, Display P3; `Tools/AppIcon/render.swift`).
    static let cue = UIColor(displayP3Red: 1, green: 0x38 / 255, blue: 0x73 / 255, alpha: 1)
    static let symbolGrey = CueInk.ui(FixedFocusText.body)

    /// What a plate shows: a symbol and words, or a rating's mark (in its
    /// own colours) and score.
    struct Badge: Equatable {
        var symbol: Symbol?
        var mark: UIImage?
        let text: String
        /// More ratings on the same plate, each its mark and score
        /// (Today's Pick: the billboard's three).
        var more: [Badge] = []
    }

    /// The card's rating, top right: the first source in Settings' order
    /// that has one (MDBList's, from the title's record), else IMDb's (the
    /// catalog's, else IMDb's own file); `sources` of them on one plate
    /// (Today's Pick three, as the billboard). None where ratings are off.
    static func rating(_ item: MetaItem, sources: Int = 1) -> Badge? {
        let settings = MDBListSettingsStore.current
        guard settings.showsRatings(onDetails: false) else { return nil }
        let catalog = item.imdbRating.flatMap { $0.isEmpty ? nil : $0 }
        let imdb = catalog ?? IMDbRatings.rating(item.id).map { MDBListProvider.imdb.format($0.value) }
        let known = TitleRecords.shared.ratings(item) ?? nil
        let entries = MDBListRatingsRow.entries(known, settings: settings, imdbFallback: imdb, onDetails: false)
            .prefix(sources).map { Badge(mark: mark($0.provider), text: $0.text) }
        guard var first = entries.first else { return nil }
        first.more = Array(entries.dropFirst())
        return first
    }

    /// A source's mark (`RatingMark`, Details' and the billboard's) as a
    /// picture, drawn as tall as the badges' symbols (the billboard's 18 pt
    /// looked small beside them), sharp: drawn at the larger scale.
    private static let markHeight: CGFloat = 22
    private static var marks: [MDBListProvider: UIImage] = [:]
    static func mark(_ provider: MDBListProvider) -> UIImage? {
        if let known = marks[provider] { return known }
        let screen = UIScreen.main.scale
        let renderer = ImageRenderer(content: RatingMark(provider: provider))
        renderer.scale = screen * markHeight / RatingMark.size
        let image = renderer.cgImage.map { UIImage(cgImage: $0, scale: screen, orientation: .up) }
        marks[provider] = image
        return image
    }

    /// A symbol and its colours. Red for an emblem (a compact solid mark:
    /// heart, sparkle, laurel, flag), two-tone where a drawing has a natural
    /// accent part (its first layer red, the rest grey), grey for a drawing
    /// or a line glyph (a person, arrows, a checkmark: in red clip art, and
    /// thin red strokes shimmer).
    struct Symbol: Equatable {
        enum Tone { case accent, red, grey }
        let name: String
        let tone: Tone
        init(_ name: String, _ tone: Tone) { self.name = name; self.tone = tone }

        var colours: [UIColor] {
            switch tone {
            case .accent: return [FixedFocusBadges.cue, FixedFocusBadges.symbolGrey]
            case .red: return [FixedFocusBadges.cue]
            case .grey: return [FixedFocusBadges.symbolGrey]
            }
        }
    }

    /// A badge's symbol by kind (two-tone ones were picked where the
    /// accent is a natural part: a circle behind a flag, a checkmark on a
    /// person, a magnifier round a sparkle, a bubble round a star looked bad).
    static func symbol(_ kind: CardBadge.Kind) -> Symbol {
        switch kind {
        case .news: return Symbol("bell.badge.fill", .accent)
        case .returns: return Symbol("calendar", .grey)
        case .finale: return Symbol("flag.checkered", .red)
        case .person: return Symbol("person.fill", .grey)
        case .gem: return Symbol("sparkle", .red)
        case .acclaimed: return Symbol("laurel.leading", .red)
        case .limited: return Symbol("square.stack.fill", .grey)
        case .top10: return Symbol("chart.line.uptrend.xyaxis", .accent)
        case .taste: return Symbol("heart.fill", .red)
        case .here: return Symbol("mappin.and.ellipse", .grey)
        }
    }

    /// A series' status ("AIRING", "RETURNING", "ENDED 2019") as a badge,
    /// in sentence case as the others ("Ended 2019").
    static func status(_ text: String) -> Badge {
        let symbol = text.hasPrefix("AIRING") ? Symbol("dot.radiowaves.left.and.right", .accent)
            : text.hasPrefix("RETURNING") ? Symbol("arrow.triangle.2.circlepath", .grey)
            : text.hasPrefix("ENDED") ? Symbol("checkmark", .grey) : Symbol("tv.fill", .grey)
        let parts = text.split(separator: " ", maxSplits: 1)
        let words = ([parts.first.map { $0.capitalized } ?? text] + parts.dropFirst().map(String.init))
            .joined(separator: " ")
        return Badge(symbol: symbol, text: words)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        ratingPlate.isHidden = true
        addSubview(ratingPlate)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The card's picture's colour (`SourceTint`), the plates a dark shade of
    /// it, the words and grey symbols in its ink: they belong to the card.
    /// Black until the colour is known.
    private(set) var tint: UIColor?

    func setTint(_ tint: UIColor?, animated: Bool) {
        guard tint != self.tint else { return }
        self.tint = tint
        let apply = { for plate in self.plates + [self.ratingPlate] { plate.tint(tint) } }
        if animated {
            UIView.animate(withDuration: Motion.fadeDuration, delay: 0, options: [.beginFromCurrentState], animations: apply)
        } else { apply() }
    }

    func show(status: String?, _ badges: [CardBadge], rating: Badge? = nil) {
        show([status.map(Self.status)].compactMap { $0 }
                + badges.map { Badge(symbol: Self.symbol($0.kind), text: $0.text) },
             rating: rating)
    }

    /// Plates given as such: a landscape card's episode top left and its
    /// state ("21m left", "Up Next", "Yesterday") top right.
    func show(_ all: [Badge], rating: Badge?) {
        isHidden = all.isEmpty && rating == nil
        if rating != self.rating {
            self.rating = rating
            ratingPlate.isHidden = rating == nil
            if let rating { ratingPlate.show(rating) }
            setNeedsLayout()
        }
        guard all != shown else { return }
        shown = all
        while plates.count < all.count {
            let plate = Plate()
            plate.tint(tint)
            addSubview(plate)
            plates.append(plate)
        }
        for (index, plate) in plates.enumerated() {
            plate.isHidden = index >= all.count
            if index < all.count { plate.show(all[index]) }
        }
        setNeedsLayout()
    }

    /// Side by side from the top left, the rating alone at the top right; a
    /// badge that doesn't fit on its line starts the next, at the left (none
    /// left out, none shortened: only one wider than the card is cut, "…").
    override func layoutSubviews() {
        super.layoutSubviews()
        var room = bounds.width
        if rating != nil {
            let width = ratingPlate.width
            ratingPlate.frame = CGRect(x: bounds.width - width, y: 0, width: width, height: Self.height)
            room = ratingPlate.frame.minX - Self.gap
        }
        var x: CGFloat = 0, y: CGFloat = 0
        for plate in plates.prefix(shown.count) {
            if x > 0, x + plate.width > room {
                x = 0
                y += Self.height + Self.gap
                room = bounds.width
            }
            let width = min(plate.width, room)
            plate.isHidden = false
            plate.frame = CGRect(x: x, y: y, width: width, height: Self.height)
            x += width + Self.gap
        }
    }

    /// A plate's colour for the card's colour (black 80 % until known): the
    /// Top Shelf's drawn plates too.
    static func plate(_ tint: UIColor?) -> UIColor { Plate.plateColour(tint) }

    /// Two lines' room: the cells lay the view out this tall.
    static let wrappedHeight = 2 * height + gap

    /// One badge: a plate in a dark shade of the card's colour (black 80 %
    /// until it's known), no edge, 10 pt corners.
    private final class Plate: UIView {
        static let symbolGap: CGFloat = 9
        private let symbol = UIImageView()
        private let label = UILabel()
        /// More ratings (`Badge.more`): each its own mark and score, laid
        /// out as the first (attached to the words, the line grew and the
        /// scores sank).
        private var extras: [(mark: UIImageView, label: UILabel)] = []
        /// Between one rating's score and the next one's mark: the
        /// billboard's.
        static let ratingGap: CGFloat = 20
        private var badge: Badge?
        private var tinted: UIColor?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = UIColor.black.withAlphaComponent(0.8)
            layer.cornerRadius = 10
            layer.cornerCurve = .continuous
            symbol.contentMode = .center
            label.lineBreakMode = .byTruncatingTail
            addSubview(symbol)
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ badge: Badge) {
            self.badge = badge
            draw()
            setNeedsLayout()
        }

        func tint(_ tint: UIColor?) {
            tinted = tint
            backgroundColor = FixedFocusBadges.plate(tint)
            draw()
        }

        /// The card's colour, deep: dark enough for the words on any picture.
        static func plate(_ tint: UIColor) -> UIColor {
            var hue: CGFloat = 0, saturation: CGFloat = 0
            tint.getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
            return UIColor(hue: hue, saturation: saturation, brightness: 0.2, alpha: 0.9)
        }
        static func plateColour(_ tint: UIColor?) -> UIColor {
            tint.map(plate) ?? UIColor.black.withAlphaComponent(0.8)
        }

        private func draw() {
            guard let badge else { return }
            let ink = { (alpha: CGFloat) in
                self.tinted.map { SourceTint.ink($0, alpha) } ?? UIColor.white.withAlphaComponent(alpha) }
            if let mark = badge.mark {
                symbol.image = mark
            } else if let glyph = badge.symbol {
                let colours = glyph.colours.map { $0 == FixedFocusBadges.symbolGrey ? ink(FixedFocusText.body) : $0 }
                symbol.image = UIImage(systemName: glyph.name, withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
                        .applying(UIImage.SymbolConfiguration(paletteColors: colours)))
            } else { symbol.image = nil }
            let words: [NSAttributedString.Key: Any] = [.font: FixedFocusBadges.font,
                                                         .foregroundColor: ink(FixedFocusText.primary)]
            label.attributedText = NSAttributedString(string: badge.text, attributes: words)
            while extras.count < badge.more.count {
                let mark = UIImageView(), score = UILabel()
                mark.contentMode = .center
                addSubview(mark)
                addSubview(score)
                extras.append((mark, score))
            }
            for (index, extra) in extras.enumerated() {
                let more = index < badge.more.count ? badge.more[index] : nil
                extra.mark.isHidden = more == nil
                extra.label.isHidden = more == nil
                extra.mark.image = more?.mark
                extra.label.attributedText = more.map { NSAttributedString(string: $0.text, attributes: words) }
            }
        }

        private var symbolWidth: CGFloat { symbol.image?.size.width.rounded(.up) ?? 0 }
        private var symbolRoom: CGFloat { symbol.image == nil ? 0 : symbolWidth + Self.symbolGap }
        private var shownExtras: [(mark: UIImageView, label: UILabel)] {
            extras.filter { !$0.label.isHidden }
        }
        private var extrasWidth: CGFloat {
            shownExtras.reduce(0) { sum, extra in
                sum + Self.ratingGap + (extra.mark.image.map { $0.size.width.rounded(.up) + Self.symbolGap } ?? 0)
                    + extra.label.intrinsicContentSize.width.rounded(.up)
            }
        }
        var width: CGFloat {
            (2 * FixedFocusBadges.padding + symbolRoom + label.intrinsicContentSize.width + extrasWidth).rounded(.up)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let pad = FixedFocusBadges.padding
            symbol.frame = CGRect(x: pad, y: 0, width: symbolWidth, height: bounds.height)
            var x = pad + symbolRoom
            let extras = shownExtras
            guard !extras.isEmpty else {
                label.frame = CGRect(x: x, y: 0, width: bounds.width - x - pad, height: bounds.height)
                return
            }
            // Each mark and score centred on the plate, as the first.
            label.frame = CGRect(x: x, y: 0, width: label.intrinsicContentSize.width.rounded(.up), height: bounds.height)
            x = label.frame.maxX
            for extra in extras {
                x += Self.ratingGap
                if let image = extra.mark.image {
                    let w = image.size.width.rounded(.up)
                    extra.mark.frame = CGRect(x: x, y: 0, width: w, height: bounds.height)
                    x += w + Self.symbolGap
                }
                let w = extra.label.intrinsicContentSize.width.rounded(.up)
                extra.label.frame = CGRect(x: x, y: 0, width: w, height: bounds.height)
                x += w
            }
        }
    }
}
