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
    static let neutral750 = Color(hex: 0x333333)
    static let neutral200 = Color(hex: 0xE0E0E0)
    static let neutral100 = Color(hex: 0xF5F5F5)
    static let red300 = Color(hex: 0xFF5252)
    static let rating = Color(hex: 0xFFD700)
    static let torrent = Color(hex: 0x7E57C2)
    static let imdb = Color(hex: 0xF5C518)
    static let success = Color(hex: 0x4CAF50)
    static let warning = Color(hex: 0xFFB74D)
    static let error = Color(hex: 0xCF6679)
}

/// The app's one look: neutral white, no accent colour, always dark.
enum CuePalette {
    static let secondary = CuePrimitives.neutral100
    static let onSecondary = CuePrimitives.neutral925
    static let focusRing = CuePrimitives.white
    static let focusBackground = Color(hex: 0x303030)
    static let background = CuePrimitives.neutral950
    static let backgroundCard = CuePrimitives.neutral850
    /// The app's text levels (`FixedFocusText`).
    static let textPrimary = Color.white.opacity(FixedFocusText.primary)
    static let textSecondary = Color.white.opacity(FixedFocusText.secondary)
    static let textTertiary = Color.white.opacity(FixedFocusText.tertiary)
}

/// The synced slice of the old theme settings. Fixed now, but still written so
/// the preferences blob keeps its shape; nothing reads it back.
struct ThemeSnapshot: Codable, Equatable {
    var paletteID: String
    var amoled: Bool
    var font: String

    static let fixed = ThemeSnapshot(paletteID: "white", amoled: false, font: "system")
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
