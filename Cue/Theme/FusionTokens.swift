import SwiftUI

// Fusion design tokens (§8–12). Typography, corner radius, motion, and
// materials for the Fusion theme. These are only consumed by Fusion-gated
// components, so Classic is unaffected.

// MARK: - Typography (§8, §9)

/// Fusion type roles at the 1920×1080 reference. Heading roles honor the Serif
/// font choice (serif face for big titles); body / metadata / technical roles
/// stay sans even when Serif is selected, exactly as the spec requires. The
/// Rounded and Monospaced choices apply everywhere.
enum FusionType {
    static func heroTitle(_ f: AppFont) -> Font { .system(size: 62, weight: .bold, design: heading(f)) }
    static func pageTitle(_ f: AppFont) -> Font { .system(size: 46, weight: .bold, design: heading(f)) }
    static func cardTitle(_ f: AppFont) -> Font { .system(size: 22, weight: .semibold, design: body(f)) }
    static func bodyText(_ f: AppFont) -> Font { .system(size: 23, weight: .regular, design: body(f)) }
    static func metadata(_ f: AppFont) -> Font { .system(size: 20, weight: .medium, design: body(f)) }
    static func button(_ f: AppFont) -> Font { .system(size: 23, weight: .semibold, design: body(f)) }
    static func badge(_ f: AppFont) -> Font { .system(size: 15, weight: .bold, design: body(f)) }

    /// Heading design: serif titles when Serif is picked, else the font's design.
    private static func heading(_ f: AppFont) -> Font.Design { f.design }
    /// Body design: sans when Serif is picked (headings only get serif), else
    /// the font's own design.
    private static func body(_ f: AppFont) -> Font.Design {
        return f == .serif ? .default : f.design
    }
}

// MARK: - Corner radius (§10)

// MARK: - Motion (§12)

/// Fusion motion language. Two easing curves — an "enter" curve
/// (cubic-bezier 0.22,1,0.36,1) and an "exit" curve (0.4,0,0.6,1) — plus the
/// named durations from the spec, so every Fusion animation feels the same.
enum FusionMotion {
    static func enter(_ d: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: d) }
    static func exit(_ d: Double) -> Animation { .timingCurve(0.4, 0, 0.6, 1, duration: d) }

    static let focusEntry = enter(0.22)
    static let focusMove = enter(0.21)
    static let pageEnter = enter(0.32)
    static let toastEnter = enter(0.22)
    static let toastExit = exit(0.20)
    static let controlsAppear = enter(0.18)
    static let controlsDismiss = exit(0.26)
    static let upNext = enter(0.30)

    static let toastVisibleSeconds: Double = 2.6
}

// MARK: - Focus geometry (§13)

/// Fusion focus treatment constants for artwork cards, so every card lifts by
/// the same amount. Portrait and landscape differ slightly per the spec.
enum FusionFocus {
    static let brightness: Double = 1.055
    static let saturation: Double = 1.035
    static let borderWidth: CGFloat = 2
    static let borderColor = Color.white.opacity(0.88)
    static func shadow(_ focused: Bool) -> Color { .black.opacity(focused ? 0.58 : 0) }
    /// The Select-press dip, shared by every theme's card button style so a
    /// press reads the same in Classic, Apple TV, Onyx, Cinematic, Marquee and
    /// Streamline. Applied via `View.cardPressDip(_:)`, which gates it on
    /// "Button animations" + Reduce Motion.
    static let pressScale: CGFloat = 0.97
    static let pressAnimation: Animation = .easeOut(duration: 0.12)
    /// The curve a focus move settles on for themes that draw their own lift
    /// (via `View.focusLift`). One value so Marquee, Streamline, Onyx,
    /// Cinematic and Aurora don't each drift to their own duration.
    static let liftAnimation: Animation = .easeOut(duration: 0.16)
}

// MARK: - Materials (§11)

/// Solid tones for floating layers where live glass is too costly (the
/// slower boxes' stand-in for `liquidGlass`).
enum FusionMaterials {
    static let dialog = Color(hex: 0x14171D, alpha: 0.94)
}

// MARK: - Motion (the ONE system, docs/UI-DESIGN.md §2)

/// Every animation in the app is one of these four. No bounce anywhere:
/// springs with bounce 0 keep their speed when a new press interrupts them
/// (fast remote swipes), which timing curves can't.
/// Rule: one press, one movement.
enum Motion {
    static let focusDuration: Double = 0.3
    static let moveDuration: Double = 0.35
    static let fadeDuration: Double = 0.25
    /// Home Up/Down (a whole row plus the box opening): longer than `move`.
    static let verticalDuration: Double = 0.5
    static let presentDuration: Double = 0.45

    /// Focus outline, highlights, button focus, presses.
    static let focus: Animation = .spring(duration: focusDuration, bounce: 0)
    /// Rows sliding, wrapping, changing row.
    static let move: Animation = .spring(duration: moveDuration, bounce: 0)
    /// Crossfades: box art, text, chrome in and out.
    static let fade: Animation = .easeInOut(duration: fadeDuration)
    /// Screen changes: billboard ⇄ Details, box → Details.
    static let present: Animation = .spring(duration: presentDuration, bounce: 0)
}
