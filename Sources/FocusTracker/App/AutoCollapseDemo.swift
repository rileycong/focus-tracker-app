import AppKit
import Foundation

/// The diagnostic harness for the mini-collapse regression (issue #37).
///
/// # Why this exists
/// Issue #37 mandates headless reproduction of the user's real failure
/// ("Collapse hides the whole app, no mini panel ever appears") BEFORE any
/// fix: an instrumented in-process probe (the #31 verification shape) is not
/// the real binary's window-server truth, so this harness drives the REAL
/// app through the REAL collapse path (the same `AppModel` calls the
/// toolbar/panel controls make) and logs enough for an EXTERNAL
/// `CGWindowList` dump (run from a separate process — no UI clicking, no
/// TCC screen-recording permission) to be correlated against the app's own
/// account of its windows.
///
/// # Launch arguments (documented, engineer's choice: the harness STAYS)
/// - `-autoCollapseDemo` — enables the demo. Without it the app is
///   completely unaffected (the check is a process-arguments test).
/// - `-autoCollapseDemoCycles <N>` — collapse/restore cycle count
///   (default 3, minimum 1).
/// - `-vaultPath <path>` — NOT a harness argument (the existing
///   `UserDefaults` argument-domain override of the configured vault path);
///   harness runs pass a temp-vault copy so the demo never reads or writes
///   the user's real vault, and nothing is persisted: the override lives
///   only in the process argument domain.
///
/// # What it does (when enabled)
/// Waits for the vault to load and the main window to appear, starts a
/// session on the first vault task (ad-hoc fallback), then runs the
/// collapse → restore cycle loop through the pinned `AppModel` entry points
/// (`collapseToMiniTimer()` / `restoreFromMiniTimer()` — the exact calls
/// the UI's Mini and restore controls make), logging a window-snapshot
/// before/after every step. Afterwards it ends the demo session through the
/// normal end flow and discards the result, so the run leaves NO pending
/// recovery snapshot behind (the app-local snapshot is cleared by the end
/// flow), and terminates the app with a logged `DEMO COMPLETE`.
///
/// Every log line is prefixed `[auto-collapse-demo]` and written
/// unbuffered to stdout so a directly-executed binary's output can be
/// captured by the driving script.
@MainActor
enum AutoCollapseDemo {

    /// The enabling launch argument (see the type documentation).
    static let launchArgument = "-autoCollapseDemo"

    /// The optional cycle-count launch argument (see the type documentation).
    static let cyclesArgument = "-autoCollapseDemoCycles"

    /// The optional fullscreen-variant launch argument: toggles the main
    /// window fullscreen before the cycle loop (the user-shaped "collapse
    /// from fullscreen" flow — the panel is `.fullScreenAuxiliary`, so the
    /// orderOut-driven Space teardown is a distinct window-server path).
    static let fullscreenArgument = "-autoCollapseDemoFullscreen"

    /// The optional log-file launch argument: `-autoCollapseDemoLog <path>`
    /// additionally tees every log line to that file (needed when the app
    /// is launched via `open`, where stdout is not capturable).
    static let logFileArgument = "-autoCollapseDemoLog"

    /// The optional long-hold variant: `-autoCollapseDemoHold <seconds>`
    /// collapses ONCE and holds for that long (snapshots every 10 s)
    /// before restoring — the late-vanish probe (a vanish that only
    /// happens after the 30 s autosave tick / ~1 s watcher ticks / SwiftUI
    /// re-renders would be invisible to the short 2 s holds).
    static let holdArgument = "-autoCollapseDemoHold"

    /// The hide/unhide variant (`-autoCollapseDemoHide`): collapse, then
    /// app-level Hide (`NSApp.hide` — Cmd+H / Dock-menu Hide, which hides
    /// ALL windows including panels regardless of `hidesOnDeactivate`),
    /// then Unhide + re-activate, snapshotting every step — and finally a
    /// repeated Mini click (the #31 epoch re-delivery) while in the
    /// post-unhide state. This is the "minimises the whole app" probe.
    static let hideArgument = "-autoCollapseDemoHide"

    /// The dock-reopen variant (`-autoCollapseDemoReopen`): collapse, then
    /// drive the Dock-icon reopen hook (`applicationShouldHandleReopen`)
    /// against the collapsed state, snapshotting every step.
    static let reopenArgument = "-autoCollapseDemoReopen"

    /// The ghost variant (`-autoCollapseDemoGhost`): collapse, then
    /// silently order out the panel's window WITHOUT dismissing it (the
    /// #31/#37 stuck-state ghost: panel gone from the window server while
    /// the flag stays on), wait past the watchdog's ~1 s cadence, and
    /// snapshot — the fixed binary must SELF-HEAL the panel back on-screen
    /// with no user input. Then restore and finish.
    static let ghostArgument = "-autoCollapseDemoGhost"

    /// The log file handle when `-autoCollapseDemoLog` was passed.
    static var logFile: FileHandle?

    /// Whether this process was launched with the demo enabled.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The requested cycle count (default 3 — the issue's 3+ repeatability
    /// criterion; clamped to at least 1).
    static var cycleCount: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: cyclesArgument),
            index + 1 < arguments.count,
            let count = Int(arguments[index + 1]), count >= 1
        else { return 3 }
        return count
    }

    /// Runs the demo end-to-end (no-op unless enabled — see `isEnabled`).
    /// The controller reference is for the snapshot evidence only.
    static func runIfNeeded(
        model: AppModel, miniPanel: MiniTimerPanelController
    ) async {
        guard isEnabled else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: logFileArgument),
            index + 1 < arguments.count
        {
            let path = arguments[index + 1]
            FileManager.default.createFile(atPath: path, contents: nil)
            logFile = FileHandle(forWritingAtPath: path)
        }
        log("enabled, cycles=\(cycleCount), arguments=\(arguments)")
        log(
            "vault path=\(model.vaultURL?.path ?? "nil") state=\(vaultStateName(model))")
        await waitForVaultLoad(model: model)
        // Let the main window finish appearing/layout before the first
        // snapshot, so the "before" evidence is the real resting state.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snapshot("before start", miniPanel: miniPanel)

        await ensureSessionStarted(model: model)
        try? await Task.sleep(nanoseconds: 500_000_000)

        if let holdSeconds = holdSeconds {
            await runLongHold(model: model, miniPanel: miniPanel, seconds: holdSeconds)
        } else if isEnabled(hideArgument) {
            await runHideVariant(model: model, miniPanel: miniPanel)
        } else if isEnabled(reopenArgument) {
            await runReopenVariant(model: model, miniPanel: miniPanel)
        } else if isEnabled(ghostArgument) {
            await runGhostVariant(model: model, miniPanel: miniPanel)
        } else {
            await runCycles(model: model, miniPanel: miniPanel)
        }

        await finishSession(model: model)
        log("DEMO COMPLETE — terminating")
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApp.terminate(nil)
    }

    /// Argument presence check with the leading dash added.
    private static func isEnabled(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// The late-vanish probe: one collapse, long hold, restore.
    private static func runLongHold(
        model: AppModel, miniPanel: MiniTimerPanelController, seconds: Double
    ) async {
        snapshot("long-hold pre-collapse", miniPanel: miniPanel)
        log("long-hold: collapseToMiniTimer(), holding \(seconds)s")
        model.collapseToMiniTimer()
        let polls = Int(seconds / 10)
        for poll in 0..<max(polls, 1) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            snapshot("long-hold +\((poll + 1) * 10)s", miniPanel: miniPanel)
        }
        log("long-hold: restoreFromMiniTimer()")
        model.restoreFromMiniTimer()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snapshot("long-hold post-restore", miniPanel: miniPanel)
    }

    /// The hide/unhide probe (see `hideArgument`).
    private static func runHideVariant(
        model: AppModel, miniPanel: MiniTimerPanelController
    ) async {
        snapshot("hide pre-collapse", miniPanel: miniPanel)
        log("hide: collapseToMiniTimer()")
        model.collapseToMiniTimer()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        snapshot("hide post-collapse (panel should be on-screen)", miniPanel: miniPanel)
        log("hide: NSApp.hide(nil)")
        NSApp.hide(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        snapshot("hide post-hide (whole app hidden)", miniPanel: miniPanel)
        log("hide: NSApp.unhide(nil) + activate")
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        snapshot("hide post-unhide (panel should be back)", miniPanel: miniPanel)
        log("hide: repeated Mini click (epoch re-delivery)")
        model.collapseToMiniTimer()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        snapshot("hide post re-collapse (panel should be on-screen)", miniPanel: miniPanel)
        log("hide: restore")
        model.restoreFromMiniTimer()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snapshot("hide post-restore (main window should be back)", miniPanel: miniPanel)
    }

    /// The dock-reopen probe (see `reopenArgument`).
    private static func runReopenVariant(
        model: AppModel, miniPanel: MiniTimerPanelController
    ) async {
        snapshot("reopen pre-collapse", miniPanel: miniPanel)
        log("reopen: collapseToMiniTimer()")
        model.collapseToMiniTimer()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        snapshot("reopen post-collapse (panel should be on-screen)", miniPanel: miniPanel)
        log("reopen: applicationShouldHandleReopen(hasVisibleWindows: false)")
        _ = NSApp.delegate?.applicationShouldHandleReopen?(
            NSApp, hasVisibleWindows: false)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        snapshot("reopen post-reopen (panel should still be the only surface)", miniPanel: miniPanel)
        log("reopen: restore")
        model.restoreFromMiniTimer()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snapshot("reopen post-restore (main window should be back)", miniPanel: miniPanel)
    }

    /// The ghost probe (see `ghostArgument`): the stuck-state reproduction.
    private static func runGhostVariant(
        model: AppModel, miniPanel: MiniTimerPanelController
    ) async {
        snapshot("ghost pre-collapse", miniPanel: miniPanel)
        log("ghost: collapseToMiniTimer()")
        model.collapseToMiniTimer()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        snapshot("ghost post-collapse (panel should be on-screen)", miniPanel: miniPanel)
        log("ghost: silently ordering the panel's window out (stuck-state ghost)")
        miniPanel.ghostOutPanelWindowForDiagnostics()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        snapshot("ghost +1s (panel silently gone, flag still on)", miniPanel: miniPanel)
        log("ghost: waiting 2.5 s for the presentation watchdog (no user input)")
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        snapshot("ghost +3.5s (watchdog must have healed the panel)", miniPanel: miniPanel)
        log("ghost: restore")
        model.restoreFromMiniTimer()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snapshot("ghost post-restore (main window should be back)", miniPanel: miniPanel)
    }

    /// The requested long-hold duration, or nil when the variant is off.
    static var holdSeconds: Double? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: holdArgument),
            index + 1 < arguments.count,
            let seconds = Double(arguments[index + 1]), seconds >= 10
        else { return nil }
        return seconds
    }

    /// The standard collapse/restore cycle loop.
    private static func runCycles(
        model: AppModel, miniPanel: MiniTimerPanelController
    ) async {
        for cycle in 1...cycleCount {
            snapshot("cycle \(cycle) pre-collapse", miniPanel: miniPanel)
            log("cycle \(cycle): collapseToMiniTimer()")
            model.collapseToMiniTimer()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            snapshot(
                "cycle \(cycle) post-collapse (panel should be on-screen)",
                miniPanel: miniPanel)
            log("cycle \(cycle): restoreFromMiniTimer()")
            model.restoreFromMiniTimer()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            snapshot(
                "cycle \(cycle) post-restore (main window should be back)",
                miniPanel: miniPanel)
        }
    }

    // MARK: - Steps

    /// Polls until the vault load lands (`bootstrap()`'s job) or times out.
    private static func waitForVaultLoad(model: AppModel) async {
        for _ in 0..<25 {
            if case .loaded = model.vaultState { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        log("WARNING: vault never reached .loaded (state=\(vaultStateName(model)))")
    }

    /// Starts a session on the first vault task (the user-shaped path) or,
    /// on an empty vault, an ad-hoc one. A pending recovery snapshot (a
    /// stale app-local leftover — never present on a clean run) is
    /// discarded first so the phase is free to start.
    private static func ensureSessionStarted(model: AppModel) async {
        if model.isSessionActive {
            log("session already active — skipping start")
            return
        }
        if model.pendingSessionRecovery != nil {
            log("discarding stale pending recovery to free the start flow")
            model.discardPendingSession()
        }
        if let first = model.tasks.first {
            let outcome = try? await model.startSession(
                taskID: first.id, duration: 3600)
            log("startSession(on \(first.title)) → \(outcomeDebug(outcome))")
        } else {
            let outcome = try? await model.startAdHocSession(
                title: "Auto-collapse demo", categoryNames: ["Demo"],
                duration: 3600)
            log("startAdHocSession → \(outcomeDebug(outcome))")
        }
    }

    /// Ends the demo session through the normal end flow and discards the
    /// unsubmitted result, leaving no pending recovery snapshot (the run
    /// must not haunt the user's next real launch).
    private static func finishSession(model: AppModel) async {
        guard case .timerView = model.appPhase, model.isSessionActive else {
            log("finish: no timer phase/session to end (phase=\(model.appPhase))")
            return
        }
        do { try model.endSession() } catch {
            log("WARNING: endSession threw \(error)")
            return
        }
        model.discardEndOfSession()
        log("finish: session ended + result discarded")
    }

    // MARK: - Evidence

    /// The app's own account of every window right now, plus the mini
    /// panel controller's live panel facts. The EXTERNAL CGWindowList dump
    /// is the independent window-server truth; this is the correlation
    /// side. Written at every demo step.
    static func snapshot(_ label: String, miniPanel: MiniTimerPanelController) {
        var lines: [String] = []
        for window in NSApp.windows {
            let frame = window.frame
            lines.append(
                "window #\(window.windowNumber) \(String(describing: type(of: window)))"
                    + " visible=\(window.isVisible) frame=\(frame)"
                    + " level=\(window.level.rawValue) alpha=\(window.alphaValue)"
                    + " occlusionVisible=\(window.occlusionState.contains(.visible))"
                    + " children=\(window.childWindows?.count ?? 0)")
        }
        log("SNAPSHOT[\(label)] app=\(NSApp.isActive ? "active" : "inactive")")
        lines.forEach { log("  \($0)") }
        log("  miniPanel: \(miniPanel.panelDiagnostics ?? "nil")")
    }

    // MARK: - Plumbing

    /// Unbuffered stdout write — piped stdout must not block-buffer the
    /// evidence away from the driving script. Teed to `-autoCollapseDemoLog`
    /// when provided (an `open`-launched run's only capturable channel).
    static func log(_ message: String) {
        let line = "[auto-collapse-demo] \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardOutput.write(data)
        try? logFile?.write(contentsOf: data)
    }

    private static func vaultStateName(_ model: AppModel) -> String {
        switch model.vaultState {
        case .notConfigured: return "notConfigured"
        case .loaded: return "loaded"
        case .vaultMissing: return "vaultMissing"
        case .tasksDirectoryMissing: return "tasksDirectoryMissing"
        }
    }

    private static func outcomeDebug(_ outcome: AppModel.SessionStartOutcome?) -> String {
        switch outcome {
        case .started(let context): return "started(\(context.title))"
        case .refused(let refusal): return "refused(\(refusal))"
        case nil: return "threw/nil"
        }
    }
}
