import SwiftUI

// The fork's design tokens: typography, motion and materials, still used
// by the old cards and the player.

// MARK: - Typography

/// Type roles at the 1920×1080 reference.
enum FusionType {
    static let heroTitle = Font.system(size: 62, weight: .bold)
    static let pageTitle = Font.system(size: 46, weight: .bold)
    static let cardTitle = Font.system(size: 22, weight: .semibold)
    static let bodyText = Font.system(size: 23, weight: .regular)
    static let metadata = Font.system(size: 20, weight: .medium)
    static let button = Font.system(size: 23, weight: .semibold)
    static let badge = Font.system(size: 15, weight: .bold)
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
    static let toastEnter = enter(0.22)
    static let toastExit = exit(0.20)

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
    /// The Select-press dip, shared by the card button styles. Applied via
    /// `View.cardPressDip(_:)`, which gates it on Reduce Motion.
    static let pressScale: CGFloat = 0.97
    static let pressAnimation: Animation = .easeOut(duration: 0.12)
    /// The curve a focus move settles on (via `View.focusLift`).
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
