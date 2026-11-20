import Foundation
import SwiftUI
import UIKit

/// Developer (Settings → Developer): the Frame Rate overlay and the
/// Playback HUD, both off by default; the Log's switch is `ProbeGate`'s.
///
/// Per device in UserDefaults, never synced.
@MainActor
final class PerformanceSettingsStore: ObservableObject {
    static let shared = PerformanceSettingsStore()

    enum FrameRate: String, Codable, CaseIterable {
        case off, compact, full
    }

    struct Settings: Codable, Equatable {
        var frameRate = FrameRate.off
        var showPlaybackHUD = false

        init() {}

        private enum CodingKeys: String, CodingKey { case frameRate, showPlaybackHUD }

        /// Lenient: a key missing from an older save keeps its default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            frameRate = (try? c.decode(FrameRate.self, forKey: .frameRate)) ?? .off
            showPlaybackHUD = (try? c.decode(Bool.self, forKey: .showPlaybackHUD)) ?? false
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

    private static let key = "cue.developer.v1"

    private init() {
        UserDefaults.standard.removeObject(forKey: "cue.performance.v1")
        UserDefaults.standard.removeObject(forKey: "cue.performance.clearStickyDiagnostics.v1")
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
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
