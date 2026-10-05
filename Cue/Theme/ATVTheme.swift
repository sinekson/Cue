import SwiftUI

extension View {
    /// Player-overlay chrome (toasts, pills, control sheets shown OVER playing
    /// video). `.ultraThinMaterial` here re-blurs the moving frame underneath on
    /// every displayed frame — one of the worst per-frame costs on the A8, and
    /// it drops playback frames while any control is up. On the low-power box
    /// fall back to a solid dark fill (visually near-identical, since these
    /// chips already sit under dark text scrims). `solid` is opaque enough that
    /// the missing blur doesn't read as a change.
    @ViewBuilder
    func playerChrome<S: Shape>(in shape: S, solid: Color = Color(hex: 0x121418).opacity(0.86)) -> some View {
        // Mid tier included: this blurs a MOVING frame on every displayed frame,
        // while the same chip is decoding it. The worst composite in the app,
        // and it was landing on the 4K gen 1 because that box is `isMidPower`.
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            self.background(solid, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// The tone hero/backdrop scrims fade into so full-bleed art dissolves into
/// `ATVBackground` without a seam — approximately the wash's color at the
/// lower-middle of the screen (the flat `palette.background` used to leave a
/// visible hard line where the hero band met the lighter graphite stage).
enum ATVStage {
    static let blend = Color(hex: 0x1E2126)
}

/// The app's background colours (Settings → Appearance): a few curated
/// dark washes — each a little lighter at the top, deeper at the bottom.
/// Settings, Search and Library always use it; Home and Movies / Series
/// below the billboard too, unless they follow the focused title.
enum AppBackground: String, CaseIterable, Identifiable {
    case slate, graphite, midnight, plum, forest

    static let storageKey = "cue.appearance.background"
    /// Home (and Movies / Series) below the billboard: the focused title's
    /// colours (on) or the app background (off).
    static let homeFollowsTitleKey = "cue.appearance.homeFollowsTitle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slate: return "Slate"
        case .graphite: return "Graphite"
        case .midnight: return "Midnight"
        case .plum: return "Plum"
        case .forest: return "Forest"
        }
    }

    var top: Color {
        switch self {
        case .slate: return Color(hex: 0x252931)
        case .graphite: return Color(red: 0.11, green: 0.11, blue: 0.115)
        case .midnight: return Color(red: 0.08, green: 0.08, blue: 0.17)
        case .plum: return Color(red: 0.13, green: 0.07, blue: 0.13)
        case .forest: return Color(red: 0.05, green: 0.11, blue: 0.09)
        }
    }

    var bottom: Color {
        switch self {
        case .slate: return Color(hex: 0x1B1E24)
        case .graphite: return Color(red: 0.04, green: 0.04, blue: 0.045)
        case .midnight: return Color(red: 0.02, green: 0.02, blue: 0.06)
        case .plum: return Color(red: 0.045, green: 0.02, blue: 0.045)
        case .forest: return Color(red: 0.015, green: 0.04, blue: 0.03)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

/// A background colour shown for a moment without being chosen: Settings →
/// Appearance → Background previews the focused colour on the whole screen.
@MainActor
final class AppBackgroundPreview: ObservableObject {
    static let shared = AppBackgroundPreview()
    @Published var choice: AppBackground?
}

/// The app's background: the chosen `AppBackground` (or the one being
/// previewed). Sits behind every screen.
struct ATVBackground: View {
    @AppStorage(AppBackground.storageKey) private var choice: AppBackground = .slate
    @ObservedObject private var preview = AppBackgroundPreview.shared

    var body: some View {
        let shown = preview.choice ?? choice
        ZStack {
            // A gradient doesn't animate between colours: the new one fades
            // in over the old (two layers only while it does).
            shown.gradient
                .id(shown)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: shown)
        .ignoresSafeArea()
    }
}
