import SwiftUI

/// Only here because a UI-testing bundle needs a host app; the driver
/// works on Cue itself (by bundle id).
@main
struct RemoteHostApp: App {
    var body: some Scene { WindowGroup { Text("Remote driver host") } }
}
