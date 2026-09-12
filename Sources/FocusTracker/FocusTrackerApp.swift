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
            // The app's default view (issue #15, PRD §8.2), styled dark and
            // calm per PRD §21 (the root enforces `.dark`; the palette in
            // `DesignTokens` is dark-first).
            TasksView(model: model)
                .task { await model.bootstrap() }
                .preferredColorScheme(.dark)
                .frame(minWidth: 640, minHeight: 420)
        }
    }
}
