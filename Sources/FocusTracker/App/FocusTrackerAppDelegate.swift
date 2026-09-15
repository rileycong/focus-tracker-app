import AppKit

/// AppKit's clean-termination callback. It performs one best-effort snapshot
/// save and implements no termination-decision method, so Cmd+Q is never
/// vetoed or left waiting even if persistence fails.
@MainActor
final class FocusTrackerAppDelegate: NSObject, NSApplicationDelegate {
    var snapshotSave: () -> Void = {}

    func applicationWillTerminate(_ notification: Notification) {
        snapshotSave()
    }
}
