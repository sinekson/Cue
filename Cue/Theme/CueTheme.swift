import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Primitive color tokens ported from Cue's Android design system.
enum CuePrimitives {
    static let black = Color(hex: 0x000000)
    static let white = Color(hex: 0xFFFFFF)
    static let neutral950 = Color(hex: 0x0D0D0D)
    static let neutral925 = Color(hex: 0x111111)
    static let neutral900 = Color(hex: 0x1A1A1A)
    static let neutral875 = Color(hex: 0x1E1E1E)
    static let neutral850 = Color(hex: 0x222222)
    static let neutral825 = Color(hex: 0x242424)
    static let neutral800 = Color(hex: 0x2D2D2D)
    static let neutral750 = Color(hex: 0x333333)
    static let neutral700 = Color(hex: 0x4D4D4D)
    static let neutral500 = Color(hex: 0x9E9E9E)
    static let neutral400 = Color(hex: 0xB3B3B3)
    static let neutral200 = Color(hex: 0xE0E0E0)
    static let neutral100 = Color(hex: 0xF5F5F5)
    static let red500 = Color(hex: 0xE53935)
    static let red600 = Color(hex: 0xC62828)
    static let red300 = Color(hex: 0xFF5252)
    static let blue500 = Color(hex: 0x1E88E5)
    static let blue700 = Color(hex: 0x1565C0)
    static let blue300 = Color(hex: 0x42A5F5)
    static let violet500 = Color(hex: 0x8E24AA)
    static let violet700 = Color(hex: 0x6A1B9A)
    static let violet300 = Color(hex: 0xAB47BC)
    static let green500 = Color(hex: 0x43A047)
    static let green700 = Color(hex: 0x2E7D32)
    static let green300 = Color(hex: 0x66BB6A)
    static let amber500 = Color(hex: 0xFB8C00)
    static let amber700 = Color(hex: 0xEF6C00)
    static let amber300 = Color(hex: 0xFFA726)
    static let rose500 = Color(hex: 0xD81B60)
    static let rose700 = Color(hex: 0xC2185B)
    static let rose300 = Color(hex: 0xEC407A)
    static let rating = Color(hex: 0xFFD700)
    static let torrent = Color(hex: 0x7E57C2)
    static let imdb = Color(hex: 0xF5C518)
    static let success = Color(hex: 0x4CAF50)
    static let warning = Color(hex: 0xFFB74D)
    static let error = Color(hex: 0xCF6679)
}

struct ThemePalette: Identifiable, Equatable {
    let id: String
    let displayName: String
    var secondary: Color
    var secondaryVariant: Color
    var onSecondary: Color = CuePrimitives.white
    var focusRing: Color
    var focusBackground: Color
    var background: Color = CuePrimitives.neutral950
    var backgroundElevated: Color = CuePrimitives.neutral900
    var backgroundCard: Color = CuePrimitives.neutral825
    var surface: Color = CuePrimitives.neutral875
    var surfaceVariant: Color = CuePrimitives.neutral800
    var panel: Color = CuePrimitives.neutral900
    var overlay: Color = Color.black.opacity(0.85)
    var field: Color = CuePrimitives.neutral850
    var playerOverlay: Color = Color.black.opacity(0.8)

    // Stored (not computed) so the Apple TV theme's light palette can swap
    // them for dark-on-light text; every palette in CueThemes keeps these
    // defaults.
    var textPrimary: Color = CuePrimitives.white
    var textSecondary: Color = CuePrimitives.neutral400
    var textTertiary: Color = CuePrimitives.neutral500

    /// The accent is LIGHT — White, Lavender, Mint. Their own ink
    /// (`onSecondary`) is dark, which is exactly what a translucent tint of
    /// them needs: a 28% tint of a light accent over the dark card is itself
    /// light, so the usual white label vanished into it. A dark accent keeps
    /// the normal light text.
    var hasLightAccent: Bool { onSecondary != CuePrimitives.white }

    /// Ink for a translucent accent TINT — the "selected" chip fill
    /// (`secondary.opacity(~0.28)`), NOT the solid accent focus fill (which
    /// uses `onSecondary` directly).
    var onAccentTint: Color { hasLightAccent ? onSecondary : textPrimary }
}

/// The app's single palette: neutral white, no accent colour.
enum CueThemes {
    static let white = ThemePalette(
        id: "white", displayName: "White",
        secondary: CuePrimitives.neutral100,
        secondaryVariant: CuePrimitives.neutral200,
        onSecondary: CuePrimitives.neutral925,
        focusRing: CuePrimitives.white,
        focusBackground: Color(hex: 0x303030),
        backgroundCard: CuePrimitives.neutral850
    )
}

/// App-wide font family (applied at the root via `.fontDesign`).
enum AppFont: String, CaseIterable, Identifiable, Codable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .monospaced: return "Monospaced"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

/// The synced slice of the theme. Every field is fixed now but still written
/// so the blob keeps its shape; fields older builds wrote are ignored.
struct ThemeSnapshot: Codable, Equatable {
    var paletteID: String
    var amoled: Bool
    var font: AppFont
}

/// The app's single look. Nothing here is configurable any more — one
/// palette, the system font, always dark — but screens read it from the
/// environment, so it stays one object.
@MainActor
final class ThemeManager: ObservableObject {
    /// App-wide font family.
    var font: AppFont { .system }
    /// Root-level font design applied app-wide.
    var rootFontDesign: Font.Design { font.design }

    /// Corner radius for settings rows.
    var settingsRowRadius: CGFloat { 12 }
    /// Corner radius for the larger settings group cards.
    var settingsCardRadius: CGFloat { 18 }

    /// The app renders dark, always.
    var preferredColorScheme: ColorScheme? { .dark }

    /// The one palette used across the app: neutral, no accent colour.
    var palette: ThemePalette { CueThemes.white }

    /// The tone full-bleed hero/backdrop scrims fade toward — the stage's
    /// graphite, so the hero band ends without a seam.
    var stageBlend: Color { ATVStage.blend }

    /// Written into the synced preferences blob so it keeps its shape; the
    /// values are the fixed look, and nothing reads them back.
    var snapshot: ThemeSnapshot {
        ThemeSnapshot(paletteID: CueThemes.white.id, amoled: false, font: font)
    }
}

/// Spacing scale ported from Cue's SpacingTokens.
enum CueSpacing {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 44
    static let huge: CGFloat = 64
}

enum CueRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
}
