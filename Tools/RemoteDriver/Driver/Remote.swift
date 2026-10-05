import XCTest

/// Plays a key sequence on the installed app with real Siri Remote presses.
///
/// Environment (passed as TEST_RUNNER_<name> through xcodebuild; see
/// `remote.sh`):
/// - `KEYS`: comma-separated steps — `up` `down` `left` `right` `select`
///   `menu` `playpause` `home`, `hold` (Select held 1 s), `wait:<seconds>`,
///   `shot:<name>` (screenshot to `SHOTS`/<name>.png), `focus` (log what
///   has focus). A step `<key>*<n>` repeats it.
/// - `LAUNCH_ARGS`: space-separated; set → the app is relaunched with them,
///   else the running app is just brought forward.
/// - `BUNDLE` (default `app.cue.tv`), `SHOTS` (screenshot folder),
///   `STEP_PAUSE` (seconds between presses, default 0.6).
final class Remote: XCTestCase {
    func testDrive() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication(bundleIdentifier: env["BUNDLE"] ?? "app.cue.tv")
        if let args = env["LAUNCH_ARGS"], !args.isEmpty {
            app.launchArguments = args.split(separator: " ").map(String.init)
            app.launch()
        } else {
            app.activate()
        }
        let pause = Double(env["STEP_PAUSE"] ?? "") ?? 0.6
        let shots = env["SHOTS"] ?? NSTemporaryDirectory()
        let remote = XCUIRemote.shared

        func logFocus(_ tag: String) {
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let what = focused.exists
                ? "\(focused.elementType.rawValue) '\(focused.label)' id='\(focused.identifier)' \(focused.frame)"
                : "nothing"
            print("REMOTE focus [\(tag)]: \(what)")
        }

        for raw in (env["KEYS"] ?? "").split(separator: ",") {
            var step = raw.trimmingCharacters(in: .whitespaces)
            var times = 1
            if let star = step.firstIndex(of: "*"), let n = Int(step[step.index(after: star)...]) {
                times = n
                step = String(step[..<star])
            }
            for _ in 0..<times {
                switch step {
                case "up": remote.press(.up)
                case "down": remote.press(.down)
                case "left": remote.press(.left)
                case "right": remote.press(.right)
                case "select": remote.press(.select)
                case "menu": remote.press(.menu)
                case "playpause": remote.press(.playPause)
                case "home": remote.press(.home)
                case "hold": remote.press(.select, forDuration: 1)
                case "focus": logFocus("now")
                default:
                    if step.hasPrefix("wait:") {
                        Thread.sleep(forTimeInterval: Double(step.dropFirst(5)) ?? 1)
                        continue
                    }
                    if step.hasPrefix("shot:") {
                        let url = URL(fileURLWithPath: shots).appendingPathComponent("\(step.dropFirst(5)).png")
                        try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
                        print("REMOTE shot: \(url.path)")
                        continue
                    }
                    XCTFail("Unknown step \(step)")
                }
                print("REMOTE step: \(step)")
                Thread.sleep(forTimeInterval: pause)
            }
        }
    }
}
