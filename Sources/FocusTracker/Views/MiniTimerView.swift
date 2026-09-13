import SwiftUI

/// The compact always-on-top mini timer (issue #21, PRD §11, §10.2, §21),
/// hosted inside `MiniTimerPanelController`'s borderless non-activating
/// `NSPanel` (the AppKit side is fully isolated there — this file stays
/// pure SwiftUI, no AppKit import).
///
/// Shows EXACTLY the PRD §11 list: the **task title** ("Parent › Child"
/// resolution, identical to #20's `TimerView`), the **countdown** —
/// monospaced digits through the same #20 `TimerDisplayState.derive` /
/// `TimerDisplay.countdownText` helpers (`m:ss` / `h:mm:ss` / `0:00`) — the
/// **current session number for that task today**, a **Pause/Resume**
/// control, and an **End/Stop** control — plus a restore affordance (the
/// display area is click-to-restore, and the panel background itself
/// drags/moves per the panel's `isMovableByWindowBackground`).
///
/// Deliberately NOT shown (pinned do-not-show list, PRD §11 — checked
/// against the final UI): project, categories, metadata, ETA, next-task
/// suggestions, analytics. Only the title's "Parent › Child" prefix
/// resolution is reused from #20; nothing else of the full timer's content.
///
/// # Session number (issue #21 criterion 2 — no refetch)
/// Read from `AppModel.sessionNumberToday` — the **#20 snapshot** lifted
/// into the model: `TimerView` fetched it once on appear and recorded it
/// here; the mini view only reads the lifted value. Same graceful-omission
/// semantics as #20: when the snapshot was unavailable (no vault, fetch
/// failure) the value is `nil` and the line is omitted, never guessed.
///
/// # Ticking (#20 pattern, issue #21 criterion 2)
/// A `TimelineView(.periodic)` re-renders about once per second and derives
/// the display state via the pure `TimerDisplayState.derive` through the
/// `AppModel` passthroughs — **no engine mutation**. While paused the
/// engine's paused accumulators freeze the countdown exactly as they freeze
/// the full view's (#12 semantics).
///
/// # End flow (issue #22, PRD §9.5, §12)
/// The End/Stop control opens the same minimal End/Cancel confirm as the
/// full timer (§9.5) and, on confirm, calls the SAME `AppModel` end path
/// (`endSession()` — both controls call the one path). The engine ends, the
/// `FocusSessionResult` is retained, and the phase swaps to
/// `.endingSession` — the observable-driven sync closes this panel and
/// restores the main window showing the timer with the blocking
/// end-of-session modal over it (the ONE presentation path, in the app
/// shell). Submission returns the app to Tasks.
struct MiniTimerView: View {
    /// The running session's display context (resolved at start, issue #19;
    /// passed through the panel controller).
    let context: AppModel.SessionContext
    /// The composition root — the same authoritative passthroughs as every
    /// other view, plus the lifted #20 session-number snapshot.
    let model: AppModel

    @State private var showsEndConfirmation = false

    var body: some View {
        VStack(spacing: DesignTokens.spacingS) {
            displayArea
            controls
        }
        .padding(DesignTokens.spacingM)
        .frame(
            width: MiniTimerPanelLayout.contentSize.width,
            height: MiniTimerPanelLayout.contentSize.height)
        .background(miniBackground)
        .confirmationDialog(
            "End this session?",
            isPresented: $showsEndConfirmation,
            titleVisibility: .visible
        ) {
            // The same `AppModel` path the full timer's End control calls
            // (issue #22): on confirm the phase enters `.endingSession` and
            // the sync closes this panel, restoring the main window with
            // the end-of-session modal over the timer.
            Button("End Session", role: .destructive, action: endSession)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The session ends now. A short wrap-up form opens before the app returns to the tasks."
            )
        }
    }

    // MARK: - Display area (title + countdown + session number)

    /// The click-to-restore display area (issue #21 criterion 3): tapping
    /// it brings the full timer back (the dedicated expand button below is
    /// the always-visible affordance). The control row is deliberately
    /// outside this gesture so Pause/End taps never restore.
    private var displayArea: some View {
        VStack(spacing: DesignTokens.spacingXS) {
            Text(displayTitle)
                .font(DesignTokens.statusGroupFont)
                .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let state = displayState()
                Text(state.countdownText)
                    .font(.system(
                        size: DesignTokens.miniCountdownSize, weight: .thin,
                        design: .monospaced))
                    .monospacedDigit()
                    .opacity(state.isPaused ? DesignTokens.pausedTextOpacity : 1)
                    .animation(DesignTokens.stateAnimation, value: state.isPaused)
            }
            // The lifted #20 snapshot; omitted entirely when it was
            // unavailable (graceful omission, same semantics as #20).
            if let number = model.sessionNumberToday {
                Text("Session \(number) today")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.restoreFromMiniTimer() }
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.spacingS) {
            // Label swaps Pause ↔ Resume (issue #20 criterion 4); paused
            // dims the countdown above.
            Button {
                togglePause()
            } label: {
                Label(
                    displayState().isPaused ? "Resume" : "Pause",
                    systemImage: displayState().isPaused ? "play.fill" : "pause.fill")
            }
            Button(role: .destructive) {
                showsEndConfirmation = true
            } label: {
                Label("End", systemImage: "stop.fill")
            }
            // Dedicated restore affordance (issue #21 criterion 3) alongside
            // the click-to-restore display area.
            Button {
                model.restoreFromMiniTimer()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .help("Restore the full timer")
        }
        .controlSize(.small)
    }

    /// The visible shape of the borderless panel: a rounded dark card
    /// matching `DesignTokens.background` (the panel itself is transparent,
    /// so these corners are the real window corners).
    private var miniBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.panelCornerRadius, style: .continuous)
            .fill(DesignTokens.background)
            .overlay(
                RoundedRectangle(
                    cornerRadius: DesignTokens.panelCornerRadius, style: .continuous)
                    .strokeBorder(DesignTokens.divider, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }

    // MARK: - Derivation + actions (mirrors of the #20 helpers)

    /// The task title — "Parent › Child" for a subtask target, the plain
    /// title otherwise (the same resolution as #20's `TimerView`).
    private var displayTitle: String {
        if let parent = context.parentTaskTitle {
            return "\(parent) › \(context.title)"
        }
        return context.title
    }

    /// One tick's display state: the engine's pure functions at the current
    /// monotonic reading, through the `AppModel` passthroughs — read-only,
    /// nothing mutates the engine (the #20 pattern).
    private func displayState() -> TimerDisplayState {
        TimerDisplayState.derive(
            remainingSeconds: model.remainingSeconds,
            progressFraction: model.progressFraction,
            isPaused: model.sessionState == .paused)
    }

    /// Pause/Resume via the same coordinator passthroughs as the full view.
    private func togglePause() {
        if model.sessionState == .paused {
            try? model.resumeSession()
        } else {
            try? model.pauseSession()
        }
    }

    /// The confirm-End handler (issue #22): the SAME `AppModel` path the
    /// full timer's End control calls. Ends the engine, retains the result
    /// and enters `.endingSession` — the sync closes this panel and
    /// restores the main window with the end-of-session modal over it.
    /// The engine refuses a second end by contract; that cannot arise from
    /// the confirm, so the typed refusal is dropped here (house style).
    private func endSession() {
        guard model.isSessionActive else { return }
        _ = try? model.endSession()
    }
}
