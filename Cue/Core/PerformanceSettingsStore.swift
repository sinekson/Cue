import Foundation
import SwiftUI
import UIKit

/// How much motion collection folder tiles may use on focus.
///
/// Collection packs ship focus artwork per folder — often 3–4 MB GIFs of
/// 120–240 frames. Decoding those is the single most expensive thing a tile can
/// do, so this is a real performance dial, not a cosmetic one. It defaults to
/// ON everywhere — the artwork is the point of these packs — and the dial in
/// Settings → Performance turns it down to stills or off when a box struggles.
enum CollectionGifQuality: String, Codable, CaseIterable, Identifiable {
    /// Animated, highest frame rate and resolution this device allows.
    case full
    /// Static focus artwork only — the hover image swaps in, nothing animates.
    /// Costs one still image per tile instead of dozens of frames.
    case partial
    /// Nothing on focus; the cover art stays put. Cheapest.
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full:    return "Full — animated"
        case .partial: return "Partial — still images"
        case .off:     return "Off"
        }
    }

    var summary: String {
        switch self {
        case .full:
            return "Play the collection's focus GIFs. The richest look, and by far the heaviest — a single GIF can be 240 frames."
        case .partial:
            return "Swap in the focus artwork as a still image. Keeps the art change on focus at a fraction of the cost."
        case .off:
            return "Leave the cover art alone on focus. Recommended on older Apple TVs."
        }
    }

    /// ON for every tier. This USED to be off on the A8/A10X boxes (a 4K gen 1
    /// froze with GIFs enabled, pre-optimization), but the silent downgrade
    /// read as "the GIFs don't work" — the artwork plays by default now and
    /// the Settings dial stays for turning it down.
    static var deviceDefault: CollectionGifQuality { .full }
}


/// User-tunable performance switches (Settings → Performance). On 4K gen-2+
/// hardware everything defaults ON — the app's full look. Older boxes start
/// with the costly effects OFF (see `tierDefaults()`); every switch remains
/// user-tunable either way, so the tier default is a starting point, not a cap.
///
/// Persisted per-device in UserDefaults and deliberately NOT synced to the
/// account: a setting tuned for the living-room 4K gen 1 shouldn't downgrade
/// a newer box on the same account.
@MainActor
final class PerformanceSettingsStore: ObservableObject {
    static let shared = PerformanceSettingsStore()

    struct Settings: Codable, Equatable {
        /// Full-screen artwork behind Home that changes as you browse.
        var heroBackdrop = true
        /// Dissolve animation when the hero artwork/info changes.
        var heroCrossfade = true
        /// Soft drop shadows under posters and cards.
        var cardShadows = true
        /// Cards spring slightly larger when focused.
        var focusZoom = true
        /// Apple TV theme only: the native tvOS card platter — the focused
        /// poster lifts and tilts/parallaxes with the trackpad. It's the
        /// heaviest per-frame focus effect (the system re-composites the whole
        /// focused card as the finger moves). OFF swaps in a lightweight
        /// scale-only focus so cards still respond, without the tilt.
        var cardParallax = true
        /// Background download of below-the-fold row artwork.
        var artworkPrefetch = true
        /// Fade posters in as they finish loading.
        var artworkFadeIn = true
        /// The sidebar's expand/collapse spring + the dim over the content.
        var sidebarAnimation = true
        /// Scale/spring on small controls (See All, tab pills, presses).
        var buttonAnimations = true
        /// Developer: live FPS counter overlaid on the app. Off by default,
        /// never set by the tier defaults — a diagnostic, not an effect.
        var showFPSOverlay = false
        /// On-screen tracing for the hold-Select menus (see HoldProbe).
        var showHoldProbe = false
        /// In-player diagnostics HUD: engine, fps, dropped frames, A/V drift,
        /// bitrate, buffer depth. Answers "why is this stuttering" on the
        /// couch, without a Mac attached.
        var showPlayerDiagnostics = false
        /// Motion allowed on collection folder tiles when focused. On by
        /// default on every tier; the Settings dial turns it down or off.
        var collectionGifQuality: CollectionGifQuality = .deviceDefault

        init() {}

        private enum CodingKeys: String, CodingKey {
            case heroBackdrop, heroCrossfade, cardShadows, focusZoom, cardParallax, showHoldProbe
            case artworkPrefetch, artworkFadeIn
            case sidebarAnimation, buttonAnimations, showFPSOverlay, showPlayerDiagnostics
            case collectionGifQuality
        }

        /// Lenient decode: a key missing from an older save keeps its default
        /// instead of failing the whole decode (which would reset every
        /// switch each time a new one ships).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heroBackdrop = (try? c.decode(Bool.self, forKey: .heroBackdrop)) ?? true
            heroCrossfade = (try? c.decode(Bool.self, forKey: .heroCrossfade)) ?? true
            cardShadows = (try? c.decode(Bool.self, forKey: .cardShadows)) ?? true
            focusZoom = (try? c.decode(Bool.self, forKey: .focusZoom)) ?? true
            cardParallax = (try? c.decode(Bool.self, forKey: .cardParallax)) ?? true
            artworkPrefetch = (try? c.decode(Bool.self, forKey: .artworkPrefetch)) ?? true
            artworkFadeIn = (try? c.decode(Bool.self, forKey: .artworkFadeIn)) ?? true
            sidebarAnimation = (try? c.decode(Bool.self, forKey: .sidebarAnimation)) ?? true
            buttonAnimations = (try? c.decode(Bool.self, forKey: .buttonAnimations)) ?? true
            showFPSOverlay = (try? c.decode(Bool.self, forKey: .showFPSOverlay)) ?? false
            showHoldProbe = (try? c.decode(Bool.self, forKey: .showHoldProbe)) ?? false
            showPlayerDiagnostics = (try? c.decode(Bool.self, forKey: .showPlayerDiagnostics)) ?? false
            collectionGifQuality = (try? c.decode(CollectionGifQuality.self, forKey: .collectionGifQuality))
                ?? .deviceDefault
        }
    }

    @Published var settings: Settings { didSet { save() } }

    /// Live mirror of the system Accessibility → Reduce Motion switch. When ON
    /// it forces the *motion* effects off regardless of the user's toggles (a
    /// Reduce Motion user still keeps non-motion polish like backdrop art and
    /// shadows). Read via the `…Effective` accessors below.
    @Published private(set) var reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled

    // MARK: Effective (motion) values — user switch AND not overridden by
    // Reduce Motion. Call sites that gate an animation read these instead of
    // `settings.x` so the system setting is honored in one place.
    var heroCrossfadeEffective: Bool { settings.heroCrossfade && !reduceMotion }
    var focusZoomEffective: Bool { settings.focusZoom && !reduceMotion }
    var sidebarAnimationEffective: Bool { settings.sidebarAnimation && !reduceMotion }
    var buttonAnimationsEffective: Bool { settings.buttonAnimations && !reduceMotion }
    var artworkFadeInEffective: Bool { settings.artworkFadeIn && !reduceMotion }
    /// The native tvOS card platter's trackpad tilt/parallax. It is a *motion*
    /// effect like the rest, so Reduce Motion suppresses it too — themes that
    /// branch on this fall back to their own flat focus visual.
    var cardParallaxEffective: Bool { settings.cardParallax && !reduceMotion }

    // MARK: Motion helpers — so every theme gates focus motion the same way
    // instead of each porting its own hardcoded scale/animation.

    /// Focus zoom for a card/tile: the theme's scale when "Cards spring
    /// slightly larger when focused" is on and Reduce Motion is off, else 1
    /// (no lift at all). Every theme's focus scale should go through this.
    func focusScale(_ scale: CGFloat, _ focused: Bool) -> CGFloat {
        focusZoomEffective && focused ? scale : 1
    }

    /// A focus/state animation that snaps instead of animating under Reduce
    /// Motion. Returns `nil` (SwiftUI's "no animation") when motion is off.
    func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// A press/control animation, additionally gated by the "Button
    /// animations" switch (Settings → Performance).
    func buttonMotion(_ animation: Animation) -> Animation? {
        buttonAnimationsEffective ? animation : nil
    }

    // MARK: Master "Performance mode"
    /// True when every optional visual effect is off — the lightest look.
    /// `artworkPrefetch` is excluded: it HELPS perceived scrolling (art is
    /// ready before you reach it), so max-performance leaves it on.
    var isMaxPerformance: Bool {
        let s = settings
        return !s.heroBackdrop && !s.heroCrossfade && !s.cardShadows
            && !s.focusZoom && !s.cardParallax && !s.artworkFadeIn
            && !s.sidebarAnimation && !s.buttonAnimations
    }

    /// One switch for all the eye-candy: ON strips every effect for max speed,
    /// OFF restores the full look. (Individual switches still work afterward.)
    func setMaxPerformance(_ on: Bool) {
        let v = !on
        var s = settings
        s.heroBackdrop = v; s.heroCrossfade = v; s.cardShadows = v
        s.focusZoom = v; s.cardParallax = v; s.artworkFadeIn = v
        s.sidebarAnimation = v; s.buttonAnimations = v
        // The label claims this turns off EVERY effect below it, and this one
        // sits in the same pane — the heaviest per-focus effect in the app (up
        // to tens of megabytes of decoded frames) and it was the one thing the
        // switch could not reach.
        if on { s.collectionGifQuality = .off }
        settings = s
    }

    /// Restore the hardware-tuned baseline for this box (the first-run defaults).
    func resetToRecommended() {
        // Diagnostics are cleared by the reset now, rather than preserved.
        //
        // Two of the three used to survive it, on the reasoning that a reset
        // shouldn't disable something you are mid-investigation on. In practice
        // the opposite is true: a reset is what someone reaches for when the
        // screen looks wrong, and an overlay drawing over the UI is one of the
        // likelier reasons it looks wrong. `showHoldProbe` was never in the
        // preserved set either, so the three behaved differently for no reason.
        settings = Self.tierDefaults()
    }

    private static let key = "cue.performance.v1"

    /// First-run defaults tuned to the hardware tier. Users who never open
    /// Settings → Performance shouldn't pay full-eye-candy jank on an A8/A10X:
    /// the costly effects start OFF there and can be re-enabled per switch.
    /// Anything the user has ever saved wins over these (see init).
    static func tierDefaults() -> Settings {
        var s = Settings()
        if PerformanceProfile.isLowPower {
            // Apple TV HD (A8 / 2 GB): keep the core artwork, but drop recurring
            // animation/composite cost. Focus is still clear via rings/borders.
            s.cardShadows = false
            s.heroCrossfade = false
            s.focusZoom = false
            s.artworkFadeIn = false
            s.sidebarAnimation = false
            s.buttonAnimations = false
            // The native card platter re-composites the focused poster on every
            // trackpad micro-movement — the heaviest per-frame focus cost on the
            // A8. Default to the lightweight scale-only focus instead.
            s.cardParallax = false
        } else if PerformanceProfile.isMidPower {
            // 4K gen 1 (A10X / 3 GB): shadows, per-cell fades and the hero
            // crossfade (now also the info-panel rebuild) are what visibly
            // cost during row scrolls; the rest it handles fine.
            s.cardShadows = false
            s.artworkFadeIn = false
            s.heroCrossfade = false
        }
        return s
    }

    private init() {
        if ProcessInfo.processInfo.arguments.contains("-lowPower") {
            // Dev tier force (see PerformanceProfile.isLowPower): show the A8's
            // real first-run defaults, not whatever this sim previously saved —
            // otherwise the forced tier runs with high-tier eye candy on and
            // measures nothing.
            settings = Self.tierDefaults()
        } else if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
            // One-shot: focus artwork used to default OFF on the A8/A10X
            // tiers, and any save since then persisted that off. Now that the
            // default is ON everywhere, flip a persisted off to full ONCE —
            // after this, an off in the store is the viewer's own choice and
            // stays put. (A deliberate pre-existing off can't be told apart
            // from the old tier default; the one-time flip is the price of
            // the new default actually reaching existing installs.)
            // Property observers do NOT fire for assignments made inside a
            // type's own initializer, so `didSet { save() }` cannot persist
            // anything the migrations below change — `migrated` tracks it and
            // the explicit `save()` at the end of init writes it. Without that,
            // a migration that ran once (its flag now set, so it never runs
            // again) was silently reverted by the still-unchanged stored blob
            // on the very next launch.
            var migrated = false

            let migrationKey = "cue.performance.gifDefaultOn.v1"
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                if settings.collectionGifQuality == .off {
                    settings.collectionGifQuality = .full
                    migrated = true
                }
            }
            // One-shot: clear the on-screen DIAGNOSTIC overlays.
            //
            // These are debugging tools that draw over the app, and they are
            // sticky — once switched on for one investigation they stay on
            // across launches and (until now) across a settings reset. That has
            // twice been reported as a rendering bug: first as "garbage in the
            // top black border" of the player, then as a "screen tear" over the
            // poster rows, which was this HUD's own 640-wide panel. Nobody
            // leaves one of these on deliberately for weeks, so clear them once
            // and let the toggles be opt-in again from a known-off state.
            let overlayKey = "cue.performance.clearStickyDiagnostics.v1"
            if !UserDefaults.standard.bool(forKey: overlayKey) {
                UserDefaults.standard.set(true, forKey: overlayKey)
                if settings.showHoldProbe || settings.showFPSOverlay || settings.showPlayerDiagnostics {
                    settings.showHoldProbe = false
                    settings.showFPSOverlay = false
                    settings.showPlayerDiagnostics = false
                    migrated = true
                    NSLog("[CuePerf] cleared sticky on-screen diagnostics left on from a previous session")
                }
            }
            if migrated { save() }
        } else {
            settings = Self.tierDefaults()
        }
        // Track the system Reduce Motion switch live so toggling it in
        // Accessibility takes effect without relaunching.
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotion = UIAccessibility.isReduceMotionEnabled
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// Developer: render bisect switches (Settings → Performance → Render bisect).
/// Each one removes ONE suspected render cost on Home so the FPS overlay can
/// tell which of them is dropping frames. Not tier defaults, not user-facing
/// polish — temporary diagnostics; delete once the culprits are fixed.
@MainActor
final class RenderProbe: ObservableObject {
    static let shared = RenderProbe()

    struct Flags: Codable, Equatable {
        /// Live glass (glassEffect / material) → a flat translucent fill.
        var noGlass = false
        /// The 3-gradient `StageScrim` over the whole stage.
        var noScrim = false
        /// Every drop shadow on Home (cards, box, logos, focus glow).
        var noShadows = false
        /// The 1.5 pt gradient rim on every card.
        var noRims = false
        /// The blurred ambient backdrop behind the rows.
        var noAmbient = false
        /// The billboard's full-screen artwork.
        var noBackdrop = false
        /// The background colour taken from the focused title (fixed dark
        /// background instead).
        var noTint = false
        /// Decode full-bleed backdrops at 2560 px instead of 3840.
        var capBackdrop = false
        /// Every animation on Home: steps snap. Tells animation cost from
        /// static drawing cost.
        var noAnimations = false
        /// New Home: the fixed box's content drifts in (a crossfade with a
        /// hint of direction); off: plain crossfade.
        var boxDrift = true
        /// New Home, Down from the billboard: the next row's name holds its
        /// spot until the cards reach it, then moves with them (off); or it
        /// moves the whole time, slower than the cards, and they meet at the
        /// row's place (on).
        var nextNameSamePace = false
        /// New Home: Continue Watching and Saved for Later with MOVING focus
        /// (the row stays, focus moves across its cards, a caption under
        /// each); off: the fixed box, at their own card size.
        var rowsMovingFocus = false
        /// New Home, moving-focus rows: how much the focused card grows, in
        /// percent (with a shadow under it); 0: it keeps its size, only
        /// outlined — as the fixed box.
        var movingFocusLift = 5
        /// …and the shadow under the grown card.
        var movingFocusShadow = true
        /// New Home: the scroll between the billboard and the rows, in
        /// seconds; 0: derived from Up / Down (√ of the longer distance).
        var billboardScrollDuration: Double = 0
        /// New Home: the billboard's / Details' summary justified (word gaps
        /// stretched to fill each line, with hyphenation); off: ragged right.
        var summaryJustified = false
        /// Details on Home's rows (the billboard, then a row per season, More
        /// Like This…); off: the old pages.
        var detailsOnRows = true
        /// Home: billboard ⇄ rows as Details' — one rigid move (≈ 800 pt, the
        /// dots end on the first row's name line), the picture stays, blurs
        /// and gives way to the colours. Off: the picture scrolls away whole.
        var homeBillboardRigid = true
        /// New Home: each poster's rim in its own colour (subtle).
        var posterRims = false
        /// New Home: the box's outline in the title's colour (off: white).
        var boxRimColored = false
        /// New Home: the rims' look (`FixedFocusRim.Style`).
        var rimStyle = "glass"
        /// New Home: the background takes the focused title's colour.
        var backgroundTint = true
        /// New Home: the background (`FixedFocusBackground`).
        var backgroundStyle = "titleColor"
        /// New Home, title colour: how long to rest on a title before the
        /// background changes, and how long the change takes (seconds).
        var tintDelay: Double = 0.08
        var tintFade: Double = 0.2
        /// The background's colour change moves WITH the focus: no rest, on
        /// the focus move's curve and duration, the neighbours' colours
        /// ready beforehand; off: after `tintDelay`, over `tintFade`.
        var tintFollowsFocus = false
        /// With `tintFollowsFocus`: presses closer together than
        /// `tintBurstGap` are a burst — the colours change at most every
        /// `tintBurstEvery`, over a calm `tintBurstBlend`; on landing (no
        /// press for a moment) the focus move's spring again.
        /// Picture's colour layout: the grid ("3x3"), the saturation
        /// multiplier, and how much of the picture's own light and dark is
        /// kept (0: every cell equally bright).
        var layoutGrid = "3x3"
        var layoutSaturation: Double = 1.1
        var layoutLightness: Double = 0
        var tintBurstCalm = true
        var tintBurstGap: Double = 0.3
        var tintBurstEvery: Double = 0.3
        var tintBurstBlend: Double = 0.5
        /// New Home: a soft glow in the background's colour.
        var backgroundGlow = false
        /// New Home, title colour: how strongly the colour covers the
        /// background (its opacity).
        var tintStrength: Double = 0.5
        /// New Home, title colour: which colour(s) of the artwork
        /// (`FixedFocusTint.Mode`), how bright, and whether warm hues get
        /// extra brightness (dark yellow reads as brown).
        var tintMode = "twoColors"
        /// Two colours: always a second one (from the picture, else made
        /// from the first — `SpotlightTint.swatches`); off: only when the
        /// picture clearly has one.
        var tintAlwaysTwo = true
        var tintBrightness: Double = 0.45
        var tintWarmBoost = true
        /// New Home, background: a soft shadow and a halo (the title's
        /// colour) behind the fixed box, darker corners, and fine grain
        /// (its opacity; 0: none).
        var boxShadow = false
        var boxGlow = false
        var vignette = false
        var grain: Double = 0
        /// The title block's badges (ENDED / ONGOING): `TitleBadge.Style`.
        var badgeStyle = "outline"
        /// New Home: the billboard's ratings (`MDBListRatingsRow.ChipStyle`).
        var billboardRatings = "chips"
        /// Details: the scrolling picture's bottom edge — "melt" (its own
        /// bottom mirrored, blurred, faded into the colours) or "shadow".
        var detailsPictureEdge = "melt"
        /// Details: how much the picture darkens on Episodes / More.
        var detailsPictureDim: Double = 0.45
        /// Details: an icon button's name under it while focused.
        var buttonCaptions = true
        /// New Home: how the cards stand off the background
        /// (`FixedFocusCardEdge`).
        var cardEdge = "topLight"
        /// Every focused card's outline: "strong" (4 pt, 85 %) or "soft"
        /// (3 pt, 75 %).
        var focusOutline = "soft"
        /// Details: how strongly the picture blurs on Episodes / More (the
        /// blur's radius on a 640 px copy; 0: none).
        var detailsPictureBlur: Double = 12
        /// Details: the blurred picture's brightness capped at this (a soft
        /// shoulder, sRGB 0…1 — `BlurredBackdrop.capCurve`): bright pictures
        /// come down, dark ones stay. 0: no cap.
        var detailsBlurCap: Double = 0
        /// Details: the rows' vignette over the blurred picture below the
        /// billboard.
        var detailsVignetteBelow = true
        /// Details' buttons: how fast they light up and grow (0: the focus
        /// motion's time — Motion: Focus).
        var buttonFocusTime: Double = 0.15
        /// The billboard's chips (status, ratings): "first" right under the
        /// logo, "last" under the tagline.
        var billboardChips = "first"
        /// The billboard's Left/Right change: "drift" (text and picture
        /// drift together) or "depthCascade" (the text further, the picture
        /// less; the text's parts one after another).
        var billboardChange = "drift"
        /// The launch screen shows what it loaded and how long it took.
        var launchNumbers = true
        /// The billboard's picture zooms very slowly while it shows.
        var billboardSlowZoom = false
        /// The left fade's strength on the Detail page's Episodes / More and
        /// behind Home's rows (0: none, 1: as on the overview / billboard).
        var episodesLeftFade: Double = 0.9
        var homeLeftFade: Double = 0
        /// New Home: how far up the billboard's picture fades into the
        /// background's colours at its bottom (points; 0: a plain edge).
        var billboardBottomFade: Double = 200
        /// No MDBList requests at all (while developing: its daily limit).
        var noMDBList = false
        /// New Home: the billboard's own, stronger vignette.
        var billboardVignette = true
        /// New Home: the billboard's scrim (`FixedFocusBillboardScrim`).
        var billboardScrim = "blackTint"
        /// New Home: the posters left of the box in the focused row (1: not
        /// dimmed).
        var previousPosterAlpha: Double = 0.45
        /// New Home: the Left/Right curve (`FixedFocusMotion.Curve`).
        var horizontalCurve = "easeInOut"
        /// New Home: the Up/Down curve.
        /// System spring (decided 2026-10-06): fast to react, smooth to land,
        /// and a press during a move carries its speed on.
        var verticalCurve = "systemSpring"
        /// The motion tokens' durations (see `Motion`).
        var motion = MotionDurations()

        init() {}

        /// Lenient: a flag missing from an older save keeps its default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Flags()
            noGlass = (try? c.decode(Bool.self, forKey: .noGlass)) ?? d.noGlass
            noScrim = (try? c.decode(Bool.self, forKey: .noScrim)) ?? d.noScrim
            noShadows = (try? c.decode(Bool.self, forKey: .noShadows)) ?? d.noShadows
            noRims = (try? c.decode(Bool.self, forKey: .noRims)) ?? d.noRims
            noAmbient = (try? c.decode(Bool.self, forKey: .noAmbient)) ?? d.noAmbient
            noBackdrop = (try? c.decode(Bool.self, forKey: .noBackdrop)) ?? d.noBackdrop
            noTint = (try? c.decode(Bool.self, forKey: .noTint)) ?? d.noTint
            capBackdrop = (try? c.decode(Bool.self, forKey: .capBackdrop)) ?? d.capBackdrop
            noAnimations = (try? c.decode(Bool.self, forKey: .noAnimations)) ?? d.noAnimations
            motion = (try? c.decode(MotionDurations.self, forKey: .motion)) ?? d.motion
            boxDrift = (try? c.decode(Bool.self, forKey: .boxDrift)) ?? d.boxDrift
            nextNameSamePace = (try? c.decode(Bool.self, forKey: .nextNameSamePace)) ?? d.nextNameSamePace
            rowsMovingFocus = (try? c.decode(Bool.self, forKey: .rowsMovingFocus)) ?? d.rowsMovingFocus
            movingFocusLift = (try? c.decode(Int.self, forKey: .movingFocusLift)) ?? d.movingFocusLift
            movingFocusShadow = (try? c.decode(Bool.self, forKey: .movingFocusShadow)) ?? d.movingFocusShadow
            billboardScrollDuration = (try? c.decode(Double.self, forKey: .billboardScrollDuration)) ?? d.billboardScrollDuration
            summaryJustified = (try? c.decode(Bool.self, forKey: .summaryJustified)) ?? d.summaryJustified
            detailsOnRows = (try? c.decode(Bool.self, forKey: .detailsOnRows)) ?? d.detailsOnRows
            homeBillboardRigid = (try? c.decode(Bool.self, forKey: .homeBillboardRigid)) ?? d.homeBillboardRigid
            posterRims = (try? c.decode(Bool.self, forKey: .posterRims)) ?? d.posterRims
            boxRimColored = (try? c.decode(Bool.self, forKey: .boxRimColored)) ?? d.boxRimColored
            rimStyle = (try? c.decode(String.self, forKey: .rimStyle)) ?? d.rimStyle
            backgroundTint = (try? c.decode(Bool.self, forKey: .backgroundTint)) ?? d.backgroundTint
            backgroundStyle = (try? c.decode(String.self, forKey: .backgroundStyle)) ?? d.backgroundStyle
            backgroundGlow = (try? c.decode(Bool.self, forKey: .backgroundGlow)) ?? d.backgroundGlow
            tintStrength = (try? c.decode(Double.self, forKey: .tintStrength)) ?? d.tintStrength
            tintMode = (try? c.decode(String.self, forKey: .tintMode)) ?? d.tintMode
            tintAlwaysTwo = (try? c.decode(Bool.self, forKey: .tintAlwaysTwo)) ?? d.tintAlwaysTwo
            tintFollowsFocus = (try? c.decode(Bool.self, forKey: .tintFollowsFocus)) ?? d.tintFollowsFocus
            tintBurstCalm = (try? c.decode(Bool.self, forKey: .tintBurstCalm)) ?? d.tintBurstCalm
            layoutGrid = (try? c.decode(String.self, forKey: .layoutGrid)) ?? d.layoutGrid
            layoutSaturation = (try? c.decode(Double.self, forKey: .layoutSaturation)) ?? d.layoutSaturation
            layoutLightness = (try? c.decode(Double.self, forKey: .layoutLightness)) ?? d.layoutLightness
            tintBurstGap = (try? c.decode(Double.self, forKey: .tintBurstGap)) ?? d.tintBurstGap
            tintBurstEvery = (try? c.decode(Double.self, forKey: .tintBurstEvery)) ?? d.tintBurstEvery
            tintBurstBlend = (try? c.decode(Double.self, forKey: .tintBurstBlend)) ?? d.tintBurstBlend
            tintBrightness = (try? c.decode(Double.self, forKey: .tintBrightness)) ?? d.tintBrightness
            tintWarmBoost = (try? c.decode(Bool.self, forKey: .tintWarmBoost)) ?? d.tintWarmBoost
            boxShadow = (try? c.decode(Bool.self, forKey: .boxShadow)) ?? d.boxShadow
            boxGlow = (try? c.decode(Bool.self, forKey: .boxGlow)) ?? d.boxGlow
            vignette = (try? c.decode(Bool.self, forKey: .vignette)) ?? d.vignette
            grain = (try? c.decode(Double.self, forKey: .grain)) ?? d.grain
            badgeStyle = (try? c.decode(String.self, forKey: .badgeStyle)) ?? d.badgeStyle
            billboardRatings = (try? c.decode(String.self, forKey: .billboardRatings)) ?? d.billboardRatings
            detailsPictureEdge = (try? c.decode(String.self, forKey: .detailsPictureEdge)) ?? d.detailsPictureEdge
            detailsPictureDim = (try? c.decode(Double.self, forKey: .detailsPictureDim)) ?? d.detailsPictureDim
            buttonCaptions = (try? c.decode(Bool.self, forKey: .buttonCaptions)) ?? d.buttonCaptions
            cardEdge = (try? c.decode(String.self, forKey: .cardEdge)) ?? d.cardEdge
            focusOutline = (try? c.decode(String.self, forKey: .focusOutline)) ?? d.focusOutline
            detailsPictureBlur = (try? c.decode(Double.self, forKey: .detailsPictureBlur)) ?? d.detailsPictureBlur
            detailsBlurCap = (try? c.decode(Double.self, forKey: .detailsBlurCap)) ?? d.detailsBlurCap
            detailsVignetteBelow = (try? c.decode(Bool.self, forKey: .detailsVignetteBelow)) ?? d.detailsVignetteBelow
            buttonFocusTime = (try? c.decode(Double.self, forKey: .buttonFocusTime)) ?? d.buttonFocusTime
            billboardChips = (try? c.decode(String.self, forKey: .billboardChips)) ?? d.billboardChips
            billboardChange = (try? c.decode(String.self, forKey: .billboardChange)) ?? d.billboardChange
            launchNumbers = (try? c.decode(Bool.self, forKey: .launchNumbers)) ?? d.launchNumbers
            billboardSlowZoom = (try? c.decode(Bool.self, forKey: .billboardSlowZoom)) ?? d.billboardSlowZoom
            episodesLeftFade = (try? c.decode(Double.self, forKey: .episodesLeftFade)) ?? d.episodesLeftFade
            homeLeftFade = (try? c.decode(Double.self, forKey: .homeLeftFade)) ?? d.homeLeftFade
            billboardBottomFade = (try? c.decode(Double.self, forKey: .billboardBottomFade)) ?? d.billboardBottomFade
            noMDBList = (try? c.decode(Bool.self, forKey: .noMDBList)) ?? d.noMDBList
            billboardVignette = (try? c.decode(Bool.self, forKey: .billboardVignette)) ?? d.billboardVignette
            billboardScrim = (try? c.decode(String.self, forKey: .billboardScrim)) ?? d.billboardScrim
            previousPosterAlpha = (try? c.decode(Double.self, forKey: .previousPosterAlpha)) ?? d.previousPosterAlpha
            tintDelay = (try? c.decode(Double.self, forKey: .tintDelay)) ?? d.tintDelay
            tintFade = (try? c.decode(Double.self, forKey: .tintFade)) ?? d.tintFade
            horizontalCurve = (try? c.decode(String.self, forKey: .horizontalCurve)) ?? d.horizontalCurve
            verticalCurve = (try? c.decode(String.self, forKey: .verticalCurve)) ?? d.verticalCurve
        }
    }

    @Published var flags: Flags {
        didSet {
            Motion.durations = flags.motion
            if let data = try? JSONEncoder().encode(flags) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    var anyOn: Bool { flags != Flags() }

    private static let key = "cue.renderProbe.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Flags.self, from: data) {
            flags = decoded
        } else {
            flags = Flags()
        }
        Motion.durations = flags.motion
    }
}

extension View {
    /// `.shadow`, skipped while the render probe's "no shadows" is on.
    @MainActor
    func probeShadow(color: Color = .black.opacity(0.33), radius: CGFloat,
                     x: CGFloat = 0, y: CGFloat = 0) -> some View {
        let off = RenderProbe.shared.flags.noShadows
        return shadow(color: off ? .clear : color, radius: off ? 0 : radius,
                      x: off ? 0 : x, y: off ? 0 : y)
    }
}
