import SwiftUI

@main
struct FocusTrackerApp: App {
    @State private var model: AppModel
    /// The always-on-top mini panel controller (issue #21): the one AppKit
    /// surface, created over the model and driven purely from the observable
    /// state by `syncMiniPanel()` below.
    @State private var miniPanel: MiniTimerPanelController
    /// The SwiftUI-lifecycle app delegate (issue #30): its
    /// `applicationShouldTerminateAfterLastWindowClosed` returns `false`
    /// exactly while the mini flag is on, so collapsing (which `orderOut`s
    /// the `Window` scene's only window) no longer terminates the app. See
    /// `FocusTrackerAppDelegate` for the pinned root-cause mechanism. It
    /// implements no other hook — in particular no
    /// `applicationShouldTerminate`, so Cmd+Q stays the default unblocked
    /// terminate path (#27).
    @NSApplicationDelegateAdaptor(FocusTrackerAppDelegate.self)
    private var appDelegate: FocusTrackerAppDelegate

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
        appDelegate.model = _model.wrappedValue
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
            // `.breakActive` countdown screen, and — the #34 amendment of
            // #23's pinned exit — the choice's Start Next Session and the
            // break's end open the session-start sheet DIRECTLY (the
            // `.sessionStart` phase; only the sheet's Cancel returns to
            // Tasks).
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
                    // verified): the modal is a plain SwiftUI sheet and
                    // nothing hooks `applicationShouldTerminate` — the one
                    // app delegate (#30) answers only the
                    // last-window-closed policy (AppKit default `true`
                    // unless mini-collapsed) and stays out of the explicit
                    // terminate path — AppKit's default terminate path ends
                    // the app normally on Cmd+Q / app-menu Quit with the
                    // sheet showing. No quit-confirmation dialog is added;
                    // quitting may lose the unsubmitted session (the
                    // documented §18 honest-loss window on
                    // `.endingSession`) — the criterion is only that
                    // quitting is not BLOCKED.
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
                case .sessionStart:
                    // The direct-to-session-start routing (issue #34,
                    // amending #23's pinned exit): the post-session
                    // choice's Start Next Session and every break end
                    // swap here. Same presentation shape as the #22
                    // modal: the sheet presents over the still-rendered
                    // previous screen — here the task list, matching
                    // where Start Next Session used to land. The sheet's
                    // pre-selection is the model's #34 last-session
                    // target (eligibility-filtered by the view), Cancel
                    // routes through `cancelSessionStart()` (no
                    // dismissal environment to fall back on), and Start
                    // runs the ordinary #19 flow (the phase swaps to
                    // `.timerView`).
                    TasksView(model: model)
                        .sheet(isPresented: .constant(true)) {
                            SessionStartView(
                                tasks: model.tasks,
                                knownCategoryNames: TaskFormState
                                    .knownCategoryNames(in: model.tasks),
                                preselectedTargetID: model.lastSessionTargetID,
                                onStart: { taskID, duration in
                                    try await model.startSession(
                                        taskID: taskID, duration: duration)
                                },
                                onStartAdHoc: { title, categoryNames, duration in
                                    try await model.startAdHocSession(
                                        title: title,
                                        categoryNames: categoryNames,
                                        duration: duration)
                                },
                                onCancel: { model.cancelSessionStart() })
                        }
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
            // Issue #31: the sync delivery keys on the presentation EPOCH,
            // not the flag. A flag-edge sync deadlocks: when a panel is lost
            // (or a delivery missed) while `isMiniTimerActive` stays on, a
            // repeated Mini click flips true→true, fires nothing, and mini
            // mode is stranded (the reported "second attempt dead"). The
            // epoch bumps on every accepted collapse/restore request, so
            // every click re-delivers the level-driven sync below.
            .onChange(of: model.miniTimerPresentationEpoch) { _, _ in syncMiniPanel() }
            .preferredColorScheme(.dark)
            .frame(minWidth: 640, minHeight: 420)
        }
    }

    /// The single place that drives the mini panel and the main window's
    /// visibility from the observable model state (issue #21 criteria 3–5;
    /// re-delivery/self-healing issue #31):
    ///
    /// # Root cause of the #31 "no mini panel appears; second attempt dead"
    /// The pre-#31 sync was driven by `.onChange(of: isMiniTimerActive)` —
    /// an EDGE. The user's stuck instance (forensically dumped live via the
    /// macOS window server: main window visible again, NO panel window in
    /// the server's window list, flag stranded on) is exactly the lost-edge
    /// deadlock: once the panel presentation diverges from the flag — a
    /// sync delivery lost in a restructure, or the panel dismissed while
    /// the flag stays on — no future state edge can repair it, and the
    /// user's next Mini click sets `true→true`, which fires nothing. The
    /// fix is structural: the sync is LEVEL-driven (it re-derives the whole
    /// presentation from current state every run) and every accepted
    /// collapse/restore request bumps `miniTimerPresentationEpoch`, so
    /// every click re-delivers a sync run — a dead/stale presentation is
    /// re-asserted (panel recreated + ordered front, window re-hidden)
    /// instead of stranding mini mode.
    ///
    /// - **Collapse** (`.timerView` + `isMiniTimerActive`): show the mini
    ///   panel without stealing focus, then `orderOut` the main window (the
    ///   pinned choice over `miniaturize` — see
    ///   `MiniTimerPanelController.hideMainWindow`). The `orderOut` makes
    ///   AppKit run its last-window-closed termination check (#30, mechanism
    ///   on `FocusTrackerAppDelegate`); the flag is already on here, so the
    ///   delegate answers `false` and the app stays running. Idempotent and
    ///   repeatable: a redundant delivery (epoch re-bump while collapsed)
    ///   re-asserts the same presentation — `MiniTimerPanelController.show`
    ///   reuses the live panel (or recreates it if it was lost) and orders
    ///   it front; `orderOut` on an already-hidden window is a no-op.
    /// - **Restore** (`.timerView`, flag off): orderFront the main window
    ///   FIRST, then dismiss the panel (issue #30 pinned order — the swap's
    ///   two halves run inside one sync so the visual difference is
    ///   imperceptible): a regular window is visible again before the
    ///   panel's `orderOut`, so the panel can never be the "last window" in
    ///   AppKit's termination check while the flag is already off — the
    ///   end-from-mini path cannot trip the check. The full
    ///   `.timerView(context)` display is intact (the phase never left
    ///   `.timerView`, so no content was torn down).
    /// - **Any end path** (`.endingSession` while the required modal is up,
    ///   then `.tasksView` after submission): bring the main window back and
    ///   dismiss the panel — covers End-from-mini (the window was hidden;
    ///   the restored main window shows the timer with the #22 modal over
    ///   it) and End-from-full (already visible; the extra orderFront is a
    ///   harmless no-op).
    ///
    /// No persistence of mini state: the app quitting takes the panel with
    /// it, and a relaunch defaults to the full view (`isMiniTimerActive` is
    /// in-memory only; the #14 recovery flow resurfaces a pending session in
    /// the full window).
    private func syncMiniPanel() {
        if case .timerView(let context) = model.appPhase, model.isMiniTimerActive {
            miniPanel.show(context: context)
            MiniTimerPanelController.hideMainWindow()
        } else {
            MiniTimerPanelController.showMainWindow()
            miniPanel.dismiss()
        }
    }
}
