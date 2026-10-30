import Foundation
import UIKit

/// Build and device info for the About page.
enum DiagnosticsService {
    /// Where the source is, as GPLv3 asks.
    static let sourceAddress = "github.com/sinekson/Cue"

    /// The marketing version; below 1.0 it's a pre-release.
    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return version.hasPrefix("0.") ? "\(version) Pre-release" : version
    }

    static var systemVersion: String {
        "tvOS \(UIDevice.current.systemVersion)"
    }

    /// The Apple TV's name; a model not listed here (a newer one): "Apple TV".
    static var deviceName: String {
        let names = [
            "AppleTV5,3": "Apple TV HD",
            "AppleTV6,2": "Apple TV 4K",
            "AppleTV11,1": "Apple TV 4K (2nd generation)",
            "AppleTV14,1": "Apple TV 4K (3rd generation)"
        ]
        return names[machine] ?? UIDevice.current.model
    }

    private static var machine: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &model, &size, nil, 0)
        return String(cString: model)
    }
}
