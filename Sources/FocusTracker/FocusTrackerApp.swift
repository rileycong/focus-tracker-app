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
            // The app-phase swap (issue #19, PRD §20.3): the start flow moves
            // the app to the placeholder timer screen; ending it returns to
            // the Tasks view. The `.task` bootstrap runs once per window —
            // the phase swap replaces the content, not the window identity.
            Group {
                switch model.appPhase {
                case .tasksView:
                    TasksView(model: model)
                case .timerView(let context):
                    SessionTimerPlaceholderView(context: context, model: model)
                }
            }
            .task { await model.bootstrap() }
            .preferredColorScheme(.dark)
            .frame(minWidth: 640, minHeight: 420)
        }
    }
}
