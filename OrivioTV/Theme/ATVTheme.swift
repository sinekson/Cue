import SwiftUI

extension View {
    /// Liquid Glass when the box runs tvOS 26+, a plain translucent material
    /// on anything older — "liquid glass if the TV accepts it".
    @ViewBuilder
    func atvGlass<S: Shape>(in shape: S) -> some View {
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            // A live glass/blur pass is one of the costliest composites on the
            // A8 Apple TV HD — and on the A10X 4K gen 1, which is `isMidPower`,
            // not `isLowPower`. Checking only the low tier meant every one of
            // these mitigations missed the box this app targets first. Back the
            // layer with a solid graphite tone instead: identical shape and
            // layout, no per-frame blur.
            self.background(FusionMaterials.dialog, in: shape)
        } else if #available(tvOS 26.0, *) {
            // BACKGROUND glass, never wrapping: a `glassEffect` wrapped around
            // focusable content can hide it from the focus engine.
            self.background(Color.clear.glassEffect(.regular, in: shape))
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

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

/// The app's background: a deep graphite wash — a touch lighter at the top,
/// slightly deeper at the bottom, but staying a medium grey (not sinking to
/// black). Sits behind every screen.
struct ATVBackground: View {
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        ZStack {
            theme.palette.background
            LinearGradient(
                colors: [Color(hex: 0x252931), Color(hex: 0x1B1E24)],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(0.92)
        }
        .ignoresSafeArea()
    }
}
