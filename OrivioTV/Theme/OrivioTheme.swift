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

/// Primitive color tokens ported from OrivioTV's Android design system.
enum OrivioPrimitives {
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
    var onSecondary: Color = OrivioPrimitives.white
    var focusRing: Color
    var focusBackground: Color
    var background: Color = OrivioPrimitives.neutral950
    var backgroundElevated: Color = OrivioPrimitives.neutral900
    var backgroundCard: Color = OrivioPrimitives.neutral825
    var surface: Color = OrivioPrimitives.neutral875
    var surfaceVariant: Color = OrivioPrimitives.neutral800
    var panel: Color = OrivioPrimitives.neutral900
    var overlay: Color = Color.black.opacity(0.85)
    var field: Color = OrivioPrimitives.neutral850
    var playerOverlay: Color = Color.black.opacity(0.8)

    // Stored (not computed) so the Apple TV theme's light palette can swap
    // them for dark-on-light text; every palette in OrivioThemes keeps these
    // defaults.
    var textPrimary: Color = OrivioPrimitives.white
    var textSecondary: Color = OrivioPrimitives.neutral400
    var textTertiary: Color = OrivioPrimitives.neutral500

    /// The accent is LIGHT — White, Lavender, Mint. Their own ink
    /// (`onSecondary`) is dark, which is exactly what a translucent tint of
    /// them needs: a 28% tint of a light accent over the dark card is itself
    /// light, so the usual white label vanished into it. A dark accent keeps
    /// the normal light text.
    var hasLightAccent: Bool { onSecondary != OrivioPrimitives.white }

    /// Ink for a translucent accent TINT — the "selected" chip fill
    /// (`secondary.opacity(~0.28)`), NOT the solid accent focus fill (which
    /// uses `onSecondary` directly).
    var onAccentTint: Color { hasLightAccent ? onSecondary : textPrimary }
}

/// The app's single palette: neutral white, no accent colour.
enum OrivioThemes {
    static let white = ThemePalette(
        id: "white", displayName: "White",
        secondary: OrivioPrimitives.neutral100,
        secondaryVariant: OrivioPrimitives.neutral200,
        onSecondary: OrivioPrimitives.neutral925,
        focusRing: OrivioPrimitives.white,
        focusBackground: Color(hex: 0x303030),
        backgroundCard: OrivioPrimitives.neutral850
    )
}

/// Light/dark preference for the Apple TV theme (Classic is always dark).
/// `system` follows the Apple TV's own Appearance setting.
enum ATVAppearance: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    /// Value handed to `.preferredColorScheme` (nil = follow the system).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
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

/// How much of the settings surface to expose (mirrors Android's
/// ExperienceMode). Essential hides the most technical options.
enum ExperienceMode: String, CaseIterable, Identifiable, Codable {
    case essential, advanced
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .essential: return "Essential"
        case .advanced: return "Advanced"
        }
    }
    var summary: String {
        switch self {
        case .essential: return "A simpler settings screen with just the everyday options"
        case .advanced: return "Every option, including engine, OSD and tuning controls"
        }
    }
    var isAdvanced: Bool { self == .advanced }
}

/// Settings-screen presentation style (mirrors Android's SettingsUiStyle).
/// Drives the corner radius of settings rows/cards.
enum SettingsUiStyle: String, CaseIterable, Identifiable, Codable {
    case classic, zen, horizon
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .zen: return "Zen"
        case .horizon: return "Horizon"
        }
    }
    var summary: String {
        switch self {
        case .classic: return "Soft rounded cards"
        case .zen: return "Pill-shaped rows"
        case .horizon: return "Sharp, squared edges"
        }
    }
    /// Corner radius for settings rows in this style.
    var rowRadius: CGFloat {
        switch self {
        case .classic: return 12
        case .zen: return 28
        case .horizon: return 2
        }
    }
    /// Corner radius for the larger settings group cards.
    var cardRadius: CGFloat {
        switch self {
        case .classic: return 18
        case .zen: return 34
        case .horizon: return 2
        }
    }
}

/// A per-axis LOOK variant — the detail page, profile screen and player overlay
/// can each independently use any theme's design (Orivio default, Marquee, or
/// Streamline), regardless of the selected app theme.
enum ThemeVariant: String, CaseIterable, Identifiable, Codable {
    case orivio, marquee, streamline
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .orivio: return "Orivio"
        case .marquee: return "Marquee"
        case .streamline: return "Streamline"
        }
    }
    func summary(_ kind: String) -> String {
        switch self {
        case .orivio: return "The default Orivio \(kind)."
        case .marquee: return "The HBO-Max-style \(kind) — pure black, white focus."
        case .streamline: return "The Hulu-style \(kind) — navy stage, accent focus."
        }
    }
}

/// The player-overlay axis. Independent of `ThemeVariant` (which still drives the
/// detail/profile axes): the player offers the original Orivio controls and
/// Fusion, an Apple-TV-style transport.
enum PlayerLayout: String, CaseIterable, Identifiable {
    case classic, fusion
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .fusion: return "Fusion"
        }
    }
    var summary: String {
        switch self {
        case .classic: return "The original Orivio playback controls."
        case .fusion: return "Apple TV\u{2011}style transport \u{2014} centred glass controls, a chapter-aware scrubber."
        }
    }
    var icon: String {
        switch self {
        case .classic: return "circle.grid.2x2.fill"
        case .fusion: return "play.circle.fill"
        }
    }
    /// Map any stored/synced string onto the two current options. Covers the
    /// retired values written while the player axis still shared `ThemeVariant`
    /// ("orivio"/"marquee"/"streamline") and the retired plain-Apple-TV layout
    /// ("hbo"). Anyone who had chosen the minimal Apple-TV transport lands on
    /// Fusion — the closest thing to what they picked — rather than being
    /// dropped back to Classic.
    init(stored raw: String?) {
        switch raw {
        case "fusion", "hbo", "marquee": self = .fusion
        default: self = .classic
        }
    }
}

extension PlayerLayout: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlayerLayout(stored: raw)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The synced slice of the theme (accent palette + AMOLED + font + experience).
struct ThemeSnapshot: Codable, Equatable {
    var paletteID: String
    var amoled: Bool
    var font: AppFont
    /// Default advanced so existing users keep the full settings surface.
    var experienceMode: ExperienceMode = .advanced
    var settingsUiStyle: SettingsUiStyle = .classic
    /// Selected app theme id. Optional so blobs written before this field
    /// (and any Android blob without it) still decode cleanly.
    var appThemeID: String? = nil
    /// Apple TV theme light/dark preference. Optional for the same
    /// backward-compatibility reason as `appThemeID`.
    var atvAppearance: ATVAppearance? = nil
    /// Independent look axes — optional so old blobs still decode.
    var detailStyle: ThemeVariant? = nil
    var profileStyle: ThemeVariant? = nil
    var playerStyle: PlayerLayout? = nil
}

@MainActor
final class ThemeManager: ObservableObject {
    /// App-wide font family (applied at the root with `.fontDesign`).
    @Published var font: AppFont {
        didSet {
            UserDefaults.standard.set(font.rawValue, forKey: scoped(Self.fontKey))
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// Settings-surface complexity (Essential hides advanced options).
    @Published var experienceMode: ExperienceMode {
        didSet {
            UserDefaults.standard.set(experienceMode.rawValue, forKey: scoped(Self.experienceKey))
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// Settings-screen presentation style (row/card shape).
    @Published var settingsUiStyle: SettingsUiStyle {
        didSet {
            UserDefaults.standard.set(settingsUiStyle.rawValue, forKey: scoped(Self.settingsStyleKey))
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// The system's resolved scheme, fed in by the root view. Defaults dark.
    @Published var systemIsDark = true

    /// Corner radius for settings rows under the current style.
    var settingsRowRadius: CGFloat { settingsUiStyle.rowRadius }
    /// Corner radius for the larger settings group cards under the current style.
    var settingsCardRadius: CGFloat { settingsUiStyle.cardRadius }

    /// Fired on a local (user-driven) theme change so the sync manager pushes it.
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    private static let fontKey = "orivio.theme.font"
    private static let experienceKey = "orivio.theme.experience"
    private static let settingsStyleKey = "orivio.theme.settingsstyle"

    /// Theme is PER PROFILE (upstream scopes `theme_settings` per profile —
    /// each family member keeps their own accent, font, and settings style).
    /// The legacy device-wide keys go to the PRIMARY profile; other profiles
    /// start at the shipped look (Trakt-switch semantics).
    private(set) var profileID: Int

    /// Separate-vs-shared switch (Trakt-style). Shared = one look for the
    /// whole device, the pre-split behaviour.
    static let feature = "theme"
    var perProfileEnabled: Bool { ProfileScopedDefaults.isSeparate(Self.feature) }

    func setPerProfile(_ on: Bool) {
        guard on != perProfileEnabled else { return }
        ProfileScopedDefaults.setSeparate(Self.feature, on)
        reloadAppearance()
    }

    private func scoped(_ base: String) -> String {
        ProfileScopedDefaults.writeKey(base, feature: Self.feature, profileID)
    }

    init() {
        let pid = ProfileScopedDefaults.activeProfileID
        profileID = pid
        let feature = Self.feature
        font = AppFont(rawValue: ProfileScopedDefaults.string(Self.fontKey, feature: feature, pid) ?? "") ?? .system
        experienceMode = ExperienceMode(rawValue: ProfileScopedDefaults.string(Self.experienceKey, feature: feature, pid) ?? "") ?? .advanced
        settingsUiStyle = SettingsUiStyle(rawValue: ProfileScopedDefaults.string(Self.settingsStyleKey, feature: feature, pid) ?? "") ?? .classic
    }

    /// Point the manager at a profile — the whole look swaps with it.
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        reloadAppearance()
    }

    /// Re-read every appearance value for the current profile + mode.
    private func reloadAppearance() {
        applyingRemote = true
        defer { applyingRemote = false }
        let feature = Self.feature
        let id = profileID
        font = AppFont(rawValue: ProfileScopedDefaults.string(Self.fontKey, feature: feature, id) ?? "") ?? .system
        experienceMode = ExperienceMode(rawValue: ProfileScopedDefaults.string(Self.experienceKey, feature: feature, id) ?? "") ?? .advanced
        settingsUiStyle = SettingsUiStyle(rawValue: ProfileScopedDefaults.string(Self.settingsStyleKey, feature: feature, id) ?? "") ?? .classic
    }

    /// Forget a deleted profile's theme so a recycled id starts from the seed.
    func forgetProfile(_ id: Int) {
        ProfileScopedDefaults.forget(
            [Self.fontKey, Self.experienceKey, Self.settingsStyleKey],
            profile: id
        )
        if id == profileID { reloadAppearance() }
    }

    /// Current theme as a syncable snapshot. The palette and AMOLED fields are
    /// fixed (one palette, never AMOLED) but still written so the blob keeps
    /// its shape; the retired per-theme axes stay nil.
    var snapshot: ThemeSnapshot {
        ThemeSnapshot(
            paletteID: OrivioThemes.white.id, amoled: false, font: font,
            experienceMode: experienceMode, settingsUiStyle: settingsUiStyle
        )
    }

    /// Apply a snapshot pulled from the account without echoing it back up.
    /// Palette, AMOLED and theme/variant fields are ignored — the app has
    /// exactly one look now.
    func applyRemote(_ s: ThemeSnapshot) {
        applyingRemote = true
        font = s.font
        experienceMode = s.experienceMode
        settingsUiStyle = s.settingsUiStyle
        applyingRemote = false
    }

    /// Root-level font design applied app-wide.
    var rootFontDesign: Font.Design { font.design }

    /// The app renders dark, always.
    var atvIsLight: Bool { false }
    var preferredColorScheme: ColorScheme? { .dark }

    /// The one palette used across the app: neutral, no accent colour.
    var palette: ThemePalette { OrivioThemes.white }

    /// The tone full-bleed hero/backdrop scrims fade toward — the stage's
    /// graphite, so the hero band ends without a seam.
    var stageBlend: Color { ATVStage.blend }

    // NOTE: `effectiveFocusGlow` and `ThemePalette.focusGlow` were removed.
    // `focusGlow` was only ever written by the never-called `ATVPalettes.adapt`,
    // so it was always `.clear` and every `.shadow(color: effectiveFocusGlow)`
    // in the app drew nothing. The no-op shadows went with it.

    // MARK: Retired theme flags — every alternate theme was deleted; these
    // stubs keep not-yet-redesigned screens on their default styling and get
    // removed as each screen is swept.
    var isAppleTVTheme: Bool { false }
    var isNetflixTheme: Bool { false }
    var isStremioTheme: Bool { false }
    var isCinemaTheme: Bool { false }
    var isOnyxTheme: Bool { false }
    var isMaxTheme: Bool { false }
    var isHuluTheme: Bool { false }
}

/// Spacing scale ported from Orivio's SpacingTokens.
enum OrivioSpacing {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 44
    static let huge: CGFloat = 64
}

enum OrivioRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
}
