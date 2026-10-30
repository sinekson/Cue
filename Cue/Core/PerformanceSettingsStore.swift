import Foundation
import SwiftUI
import UIKit

/// Developer switches (Settings → Performance): diagnostics, all off by
/// default.
///
/// Persisted per-device in UserDefaults and deliberately NOT synced to the
/// account: a setting tuned for the living-room 4K gen 1 shouldn't downgrade
/// a newer box on the same account.
@MainActor
final class PerformanceSettingsStore: ObservableObject {
    static let shared = PerformanceSettingsStore()

    struct Settings: Codable, Equatable {
        /// Developer: live FPS counter overlaid on the app. Off by default,
        /// never set by the tier defaults — a diagnostic, not an effect.
        var showFPSOverlay = false
        /// In-player diagnostics HUD: engine, fps, dropped frames, A/V drift,
        /// bitrate, buffer depth. Answers "why is this stuttering" on the
        /// couch, without a Mac attached.
        var showPlayerDiagnostics = false

        init() {}

        private enum CodingKeys: String, CodingKey {
            case showFPSOverlay, showPlayerDiagnostics
        }

        /// Lenient decode: a key missing from an older save keeps its default
        /// instead of failing the whole decode (which would reset every
        /// switch each time a new one ships).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            showFPSOverlay = (try? c.decode(Bool.self, forKey: .showFPSOverlay)) ?? false
            showPlayerDiagnostics = (try? c.decode(Bool.self, forKey: .showPlayerDiagnostics)) ?? false
        }
    }

    @Published var settings: Settings { didSet { save() } }

    /// Live mirror of the system Accessibility → Reduce Motion switch. When ON
    /// it turns the *motion* effects off (focus zoom, the card platter's
    /// tilt, the top bar's and controls' springs, artwork fade-in); non-motion
    /// polish like shadows stays.
    @Published private(set) var reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled

    /// Motion effects allowed: Reduce Motion is off.
    var motionOn: Bool { !reduceMotion }

    // MARK: Motion helpers — so every theme gates focus motion the same way
    // instead of each porting its own hardcoded scale/animation.

    /// Focus zoom for a card/tile: the theme's scale unless Reduce Motion
    /// is on, else 1 (no lift at all). Every theme's focus scale should go
    /// through this.
    func focusScale(_ scale: CGFloat, _ focused: Bool) -> CGFloat {
        motionOn && focused ? scale : 1
    }

    /// A focus/state animation that snaps instead of animating under Reduce
    /// Motion. Returns `nil` (SwiftUI's "no animation") when motion is off.
    func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// A press/control animation (none under Reduce Motion).
    func buttonMotion(_ animation: Animation) -> Animation? {
        motionOn ? animation : nil
    }

    private static let key = "cue.performance.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
            // Property observers do NOT fire for assignments made inside a
            // type's own initializer, so `didSet { save() }` cannot persist
            // anything the migration below changes — `migrated` tracks it and
            // the explicit `save()` writes it.
            var migrated = false
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
                if settings.showFPSOverlay || settings.showPlayerDiagnostics {
                    settings.showFPSOverlay = false
                    settings.showPlayerDiagnostics = false
                    migrated = true
                    NSLog("[CuePerf] cleared sticky on-screen diagnostics left on from a previous session")
                }
            }
            if migrated { save() }
        } else {
            settings = Settings()
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

/// Developer switches (Settings → Render Lab), per device.
@MainActor
final class RenderProbe: ObservableObject {
    static let shared = RenderProbe()

    struct Flags: Codable, Equatable {
        /// The launch screen shows what it loaded and how long it took.
        var launchNumbers = true

        init() {}

        /// Lenient: a flag missing from an older save keeps its default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Flags()
            launchNumbers = (try? c.decode(Bool.self, forKey: .launchNumbers)) ?? d.launchNumbers
        }
    }

    @Published var flags: Flags {
        didSet {
            if let data = try? JSONEncoder().encode(flags) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    private static let key = "cue.renderProbe.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Flags.self, from: data) {
            flags = decoded
        } else {
            flags = Flags()
        }
    }
}
