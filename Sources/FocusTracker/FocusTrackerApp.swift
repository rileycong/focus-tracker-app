import SwiftUI

@main
struct FocusTrackerApp: App {
    @State private var model: AppModel

    init() {
        // The vault path lives in the app's UserDefaults suite; the suite
        // falling back to `.standard` is a deliberate, visible fallback for
        // the practically unreachable unavailable-suite case (#14).
        let settings: AppSettings
        do {
            settings = try AppSettings(suiteName: AppSettings.defaultSuiteName)
        } catch {
            settings = AppSettings(defaults: .standard)
        }
        _model = State(initialValue: AppModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            Text("Focus Tracker")
                .task { await model.bootstrap() }
        }
    }
}