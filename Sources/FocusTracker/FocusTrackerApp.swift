import SwiftUI

@main
struct FocusTrackerApp: App {
    @State private var model: AppModel
    /// The always-on-top mini panel controller (issue #21): the one AppKit
    /// surface, created over the model and driven purely from the observable
    /// state by `syncMiniPanel()` below.
    @State private var miniPanel: MiniTimerPanelController

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
        _miniPanel = State(initialValue: MiniTimerPanelController(model: _model.wrappedValue))
    }

    var body: some Scene {
        WindowGroup {
            // The app-phase swap (issue #19, PRD §20.3; end flow issue #22):
            // the start flow moves the app to the full-screen timer view
            // (issue #20); confirming End moves it to `.endingSession` — the
            // timer stays rendered with the blocking end-of-session modal
            // over it — and the required submission returns to Tasks.
            // The `.task` bootstrap runs once per window — the phase swap
            // replaces the content, not the window identity.
            Group {
                switch model.appPhase {
                case .tasksView:
                    TasksView(model: model)
                case .timerView(let context):
                    TimerView(context: context, model: model)
                case .endingSession(let result, let context):
                    // The end-of-session modal (issue #22, PRD §12): ONE
                    // presentation path, driven by the phase right here in
                    // the app shell — never duplicated per view. The sheet
                    // exists exactly while the phase is `.endingSession`
                    // (submission flips the phase; the sheet leaves with
                    // the branch), and interactive dismissal is disabled —
                    // submission is REQUIRED (§12.5).
                    TimerView(context: context, model: model)
                        .sheet(isPresented: .constant(true)) {
                            EndOfSessionModalView(
                                result: result, context: context, model: model)
                                .interactiveDismissDisabled(true)
                        }
                }
            }
            .task { await model.bootstrap() }
            // The mini-panel ↔ main-window sync (issue #21): fires on a
            // collapse (`isMiniTimerActive` flip while the phase stays
            // `.timerView`), on a restore (flag off), and on any end path
            // (phase → `.endingSession`, flag already cleared by
            // `endSession()`).
            .onChange(of: model.appPhase) { _, _ in syncMiniPanel() }
            .onChange(of: model.isMiniTimerActive) { _, _ in syncMiniPanel() }
            .preferredColorScheme(.dark)
            .frame(minWidth: 640, minHeight: 420)
        }
    }

    /// The single place that drives the mini panel and the main window's
    /// visibility from the observable model state (issue #21 criteria 3–5):
    ///
    /// - **Collapse** (`.timerView` + `isMiniTimerActive`): show the mini
    ///   panel without stealing focus, then `orderOut` the main window (the
    ///   pinned choice over `miniaturize` — see
    ///   `MiniTimerPanelController.hideMainWindow`).
    /// - **Restore** (`.timerView`, flag off): dismiss the panel and orderFront
    ///   the main window — the full `.timerView(context)` display is intact
    ///   (the phase never left `.timerView`, so no content was torn down).
    /// - **Any end path** (`.endingSession` while the required modal is up,
    ///   then `.tasksView` after submission): dismiss the panel and bring
    ///   the main window back — covers End-from-mini (the window was
    ///   hidden; the restored main window shows the timer with the #22
    ///   modal over it) and End-from-full (already visible; the extra
    ///   orderFront is a harmless no-op).
    ///
    /// No persistence of mini state: the app quitting takes the panel with
    /// it, and a relaunch starts on the full view (`isMiniTimerActive` is
    /// in-memory only; the #14 recovery flow resurfaces a pending session in
    /// the full window).
    private func syncMiniPanel() {
        if case .timerView(let context) = model.appPhase, model.isMiniTimerActive {
            miniPanel.show(context: context)
            MiniTimerPanelController.hideMainWindow()
        } else {
            miniPanel.dismiss()
            MiniTimerPanelController.showMainWindow()
        }
    }
}
