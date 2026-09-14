import SwiftUI

/// The blocking recovery prompt (issue #36, PRD §9.5): shown over the task
/// list exactly while `AppModel.AppPhase.recoveryPrompt` is active —
/// presented by the app shell (the ONE presentation path; this view never
/// presents itself). It closes the gap #14 deferred to #20/#22: with a
/// recovered (unfinished) session on disk, starts are refused (#19's
/// `.pendingRecoveryUnresolved` backstop), so this prompt is the only way
/// forward — resume the session into the timer, or discard it and stay on
/// Tasks.
///
/// # Content
/// The recovered session's task title (resolved from the snapshot's task ID
/// at surfacing; unknown ID → the generic wording) and its accumulated
/// focused time — an honest readout of what resuming continues and what
/// discarding loses.
///
/// # Actions
/// - **Resume session** → `AppModel.restorePendingSession()` (the #14 API):
///   the engine is restored per #13 (an already-expired snapshot resumes at
///   its expiry-instant state per #33), autosave re-armed, phase →
///   `.timerView`.
/// - **Discard session** → typed, destructive confirm first (the session was
///   never logged — the honest §18 loss) → `AppModel.discardPendingSession()`:
///   snapshot cleared, phase → `.tasksView`, starts allowed.
///
/// Interactive dismissal stays disabled (the #22/#29 submission-required
/// pattern): the prompt resolves only through its two explicit actions.
struct RecoveryPromptView: View {
    /// The recovered session's persisted image — the focused-time readout
    /// and the identity the actions resolve.
    let snapshot: ActiveSessionSnapshot
    /// The display context resolved once at surfacing (the #36 payload).
    let context: AppModel.SessionContext
    /// The composition root — the two pinned resolution paths.
    let model: AppModel

    @State private var showsDiscardConfirmation = false
    @State private var failureText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                Text("Unfinished session")
                    .font(DesignTokens.titleFont)
                Text(displayTitle)
                    .font(DesignTokens.statusGroupFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(focusedMinutes) min focused")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
            if let failureText = failureText {
                Text(failureText)
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(DesignTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Discard session…", role: .destructive) {
                    showsDiscardConfirmation = true
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Resume session", action: resume)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(width: 420)
        .confirmationDialog(
            "Discard this recovered session?",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard session", role: .destructive, action: discard)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(
                "The session was never logged — discarding permanently loses "
                    + "its \(focusedMinutes) minutes of focused time. "
                    + "Nothing is written to the vault.")
        }
    }

    // MARK: - Pieces

    /// "Parent › Child" for a subtask target, the plain title otherwise —
    /// the same resolution the end-of-session modal and the timer use.
    private var displayTitle: String {
        if let parent = context.parentTaskTitle {
            return "\(parent) › \(context.title)"
        }
        return context.title
    }

    /// The accumulated focused time in whole minutes (the #12 rounding rule
    /// — the same nearest-minute helper the end flow composes with).
    private var focusedMinutes: Int {
        EndOfSessionFormState.nearestMinute(
            fromSeconds: snapshot.accumulatedFocusedSeconds)
    }

    // MARK: - Actions

    /// Resume session (issue #36): the pinned #14 restore — engine restored
    /// (running/paused exactly as the snapshot carries it), autosave
    /// re-armed, the phase swaps to `.timerView` (the prompt leaves with the
    /// shell's branch swap). The only possible throw (`restore`'s
    /// `.sessionAlreadyActive`) is impossible from this state — no engine
    /// lifecycle is open while the prompt is up — but is surfaced inline,
    /// never swallowed (the #29 Cancel precedent).
    private func resume() {
        failureText = nil
        do {
            try model.restorePendingSession()
        } catch {
            failureText = String(describing: error)
        }
    }

    /// The confirmed destructive action: drops the recovered session via
    /// `AppModel.discardPendingSession()` — the honest §18 loss (the session
    /// was never logged; the on-disk snapshot is cleared so it cannot
    /// resurface) — and returns to Tasks, starts allowed.
    private func discard() {
        failureText = nil
        model.discardPendingSession()
    }
}
