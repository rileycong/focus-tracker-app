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
        // SINGLE WINDOW (issue #27 amendment): the #19 phase-driven shell
        // used to live in a `WindowGroup`, so File → New Window / Cmd+N
        // opened a duplicate whose own phase-driven content re-presented the
        // REQUIRED `.endingSession` modal — a second, equally inescapable
        // copy of it. The macOS 14 `Window` scene makes the app
        // single-window: exactly one window can ever exist, so the modal can
        // never re-present anywhere else. This is the deliberate utility-app
        // shape (PRD §23: "keep the app small enough to behave like a
        // utility rather than a workspace") — one task list, one focus
        // session, one window; no multi-window feature is given up because
        // none is offered.
        Window("Focus Tracker", id: "main") {
            // The app-phase swap (issue #19, PRD §20.3; end flow issue #22;
            // break flow issue #23): the start flow moves the app to the
            // full-screen timer view (issue #20); confirming End moves it to
            // `.endingSession` — the timer stays rendered with the blocking
            // end-of-session modal over it — the required submission stops
            // at `.postSessionChoice` (issue #23: Start Next Session /
            // Take Break, NOTHING auto-starting), a running break shows the
            // `.breakActive` countdown screen, and the choice's controls (or
            // the break's end) return to Tasks.
            // The `.task` bootstrap runs once — the scene's single window
            // (issue #27 amendment) is the only bootstrap site; the phase
            // swap replaces the content, not the window identity.
            Group {
                switch model.appPhase {
                case .tasksView:
                    TasksView(model: model)
                case .timerView(let context):
                    TimerView(context: context, model: model)
                case .endingSession(let result, _, let context):
                    // The end-of-session modal (issue #22, PRD §12): ONE
                    // presentation path, driven by the phase right here in
                    // the app shell — never duplicated per view. The sheet
                    // exists exactly while the phase is `.endingSession`
                    // (submission or the #29 Cancel flips the phase; the
                    // sheet leaves with the branch), and interactive
                    // dismissal is disabled — the flow resolves only
                    // through an explicit control (§12.5; #29 keeps the
                    // dismissal disabled and makes the Cancel BUTTON the
                    // affordance). Issue #27: the modal now also offers
                    // Discard (typed confirm) after a failed append, so it
                    // can never trap. The phase's middle payload member
                    // (the #29 end-instant snapshot) is consumed by
                    // `AppModel.cancelEndOfSession` — the shell never
                    // touches it.
                    //
                    // Quit is NOT blocked while this modal is up (#27,
                    // verified): there is no `NSApplicationDelegate` and no
                    // `applicationShouldTerminate` anywhere in the app (the
                    // only AppKit surface is the #21 mini panel, which adds
                    // none), and this is a plain SwiftUI sheet — AppKit's
                    // default terminate path ends the app normally on
                    // Cmd+Q / app-menu Quit with the sheet showing. No
                    // quit-confirmation dialog is added; quitting may lose
                    // the unsubmitted session (the documented §18
                    // honest-loss window on `.endingSession`) — the
                    // criterion is only that quitting is not BLOCKED.
                    // Amendment (#27): with the single-window scene above,
                    // the "stuck" experience is impossible three ways —
                    // Discard escapes a failed append, there is no second
                    // window to re-present the modal in, and nothing hooks
                    // termination.
                    TimerView(context: context, model: model)
                        .sheet(isPresented: .constant(true)) {
                            EndOfSessionModalView(
                                result: result, context: context, model: model)
                                .interactiveDismissDisabled(true)
                        }
                case .postSessionChoice(let completionFailure):
                    // The post-submission choice (issue #23, PRD §14.1):
                    // inline view (engineer's choice, documented on the
                    // phase) in the same ONE phase-driven path. The payload
                    // carries the #22 partial-outcome failure for the inline
                    // warning.
                    PostSessionChoiceView(
                        model: model, completionFailure: completionFailure)
                case .breakActive:
                    // The break countdown (issue #23, PRD §14.2): the same
                    // ONE phase-driven path; the view derives everything
                    // from the model's break passthroughs.
                    BreakView(model: model)
                }
            }
            // The break-log warning (issue #23 criterion 18): the small
            // non-blocking banner for an append failure on the non-blocking
            // break path — the flow already continued to Tasks; the warning
            // rides above whatever phase is showing until the next break
            // clears it.
            .overlay(alignment: .bottom) {
                if let warning = model.pendingBreakLogWarning {
                    Text(warning)
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(DesignTokens.warning)
                        .padding(.horizontal, DesignTokens.spacingM)
                        .padding(.vertical, DesignTokens.spacingS)
                        .background(DesignTokens.bannerBackground)
                        .cornerRadius(DesignTokens.cornerRadius)
                        .padding(.bottom, DesignTokens.spacingM)
                        .transition(.opacity)
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
