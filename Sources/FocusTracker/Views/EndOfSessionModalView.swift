import SwiftUI

/// The blocking end-of-session modal (issue #22, PRD §12): shown over the
/// full timer exactly while `AppPhase.endingSession` is active — presented
/// by the app shell (the ONE presentation path; this view never presents
/// itself). The phase only leaves `.endingSession` through
/// `AppModel.submitEndOfSession`, `AppModel.cancelEndOfSession` (#29) or
/// `AppModel.discardEndOfSession` (#27). Interactive dismissal stays
/// disabled: the flow resolves only through an explicit control, and the
/// #29 Cancel BUTTON is the way back — Esc is deliberately kept dead (no
/// `.keyboardShortcut(.cancelAction)`), matching the pre-#29 modal where
/// Esc did nothing.
///
/// # Fields (§12.1–§12.4, exact)
/// **Completed task?** Yes/No selectable buttons — no default selected, the
/// user must choose; **Focus level** and **Energy level** 1–5 selectable
/// buttons; **Notes** free text — optional, empty allowed. All validation
/// lives in the pure `EndOfSessionFormState` (`isSubmittable`), which the
/// submit button binds to; this view holds no logic of its own.
///
/// # Outcomes
/// - `.success` — the phase moved to `.postSessionChoice` (#23); the sheet
///   leaves with the app-shell branch swap.
/// - `.logAppendFailed` — nothing was written; the ending state is retained
///   (the phase is untouched, the sheet stays up) and the failure is
///   surfaced inline for retry. The modal is never a trap (issue #27): a
///   destructive **Discard session log** control appears alongside the
///   retry — typed confirm (confirmation dialog, destructive-styled button)
///   drops the in-memory result (the documented honest §18 loss — the
///   unsubmitted session exists only in memory, the snapshot was already
///   cleared at confirm) and the phase moves to `.tasksView` with nothing
///   written.
/// - `.completionFailedAfterLog` — the documented partial outcome: the
///   session IS logged, the status is NOT updated; the app returns to Tasks,
///   where the user can complete the task manually in the UI.
/// - **Cancel** (issue #29) — closes the modal WITHOUT logging and resumes
///   the session: the retained result is discarded as a log (nothing is
///   appended) and the session is restored from the end-instant snapshot
///   (`AppModel.cancelEndOfSession`, the #13 restore path) — running-at-end
///   keeps running (modal time counts as nothing), paused-at-end comes back
///   paused. The phase returns to `.timerView` and the sheet leaves with
///   the branch swap.
struct EndOfSessionModalView: View {
    /// The retained engine result — the §13 log's timing fields.
    let result: FocusSessionResult
    /// The session's display context (which work the answers are about).
    let context: AppModel.SessionContext
    /// The composition root — the pinned submission path
    /// (`AppModel.submitEndOfSession`).
    let model: AppModel

    @State private var form = EndOfSessionFormState()
    @State private var submissionFailureText: String?
    @State private var showsDiscardConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            header
            completedSection
            ratingSection(title: "Focus level", selection: $form.focusRating)
            ratingSection(title: "Energy level", selection: $form.energyRating)
            notesSection
            if let failureText = submissionFailureText {
                Text(failureText)
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(DesignTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if submissionFailureText != nil {
                    // The #27 escape hatch, offered alongside retry exactly
                    // while the append failure is surfaced: destructive,
                    // behind a typed confirmation (see `discard()`).
                    Button("Discard session log…", role: .destructive) {
                        showsDiscardConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Discard this session's log?",
                        isPresented: $showsDiscardConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Discard session log", role: .destructive, action: discard)
                        Button("Keep editing", role: .cancel) {}
                    } message: {
                        Text(
                            "The unsubmitted session exists only in memory — "
                                + "discarding loses it permanently. Nothing is written to the vault.")
                    }
                }
                Spacer()
                // Issue #29: the way back from the modal WITHOUT logging —
                // styled as the calm secondary action beside Save (tokens:
                // the bordered style the flow's other non-destructive
                // controls use). Always enabled: Cancel is valid in every
                // modal state, including a failed append.
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                Button("Save session", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.isSubmittable)
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(width: 420)
    }

    // MARK: - Pieces (§12.1–§12.4, in order)

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Session complete")
                .font(DesignTokens.titleFont)
            Text(displayTitle)
                .font(DesignTokens.statusGroupFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(result.focusedDuration) min focused")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
        }
    }

    /// "Parent › Child" for a subtask target, the plain title otherwise —
    /// the same resolution the timer views use.
    private var displayTitle: String {
        if let parent = context.parentTaskTitle {
            return "\(parent) › \(context.title)"
        }
        return context.title
    }

    /// §12.1: Yes/No selectable buttons, no default (the pure state's
    /// optional `completedChoice` stays `nil` until one is picked).
    private var completedSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Text("Completed task?")
                .font(DesignTokens.statusGroupFont)
            HStack(spacing: DesignTokens.spacingS) {
                choiceButton("Yes", selected: form.completedChoice == .yes) {
                    form.completedChoice = .yes
                }
                choiceButton("No", selected: form.completedChoice == .no) {
                    form.completedChoice = .no
                }
            }
        }
    }

    /// §12.2/§12.3: the 1–5 selectable buttons for one rating.
    private func ratingSection(title: String, selection: Binding<Int?>) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Text(title)
                .font(DesignTokens.statusGroupFont)
            HStack(spacing: DesignTokens.spacingS) {
                ForEach(EndOfSessionFormState.ratingRange, id: \.self) { value in
                    choiceButton("\(value)", selected: selection.wrappedValue == value) {
                        selection.wrappedValue = value
                    }
                }
            }
        }
    }

    /// §12.4: free-text notes — optional, no structured prompt.
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Text("Notes")
                .font(DesignTokens.statusGroupFont)
            TextField(
                "Optional — anything worth remembering",
                text: $form.notes,
                axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
        }
    }

    /// A selectable pill button (§12's "selectable buttons"): the neutral
    /// chip surface when unselected, the app's selection wash when chosen.
    private func choiceButton(
        _ label: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(DesignTokens.statusGroupFont)
                .padding(.horizontal, DesignTokens.spacingM)
                .padding(.vertical, DesignTokens.spacingXS)
                .background(
                    selected
                        ? DesignTokens.selectionBackground
                        : DesignTokens.chipBackground)
                .cornerRadius(DesignTokens.cornerRadius)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submission

    /// The pinned submission path (issue #22 criterion 13). A
    /// `.logAppendFailed` keeps the modal up (the model retains the ending
    /// state) and surfaces the failure inline for retry; every other
    /// outcome moves the phase to `.tasksView`, so the sheet leaves with
    /// the app-shell branch swap — including the documented partial
    /// `.completionFailedAfterLog` (logged, not completed, back on Tasks).
    private func submit() {
        Task {
            do {
                if case .logAppendFailed(let error) = try await model.submitEndOfSession(form) {
                    submissionFailureText = error.description
                }
            } catch {
                // Outside the typed outcome surface (the stores' contracts
                // define every failure this flow can hit) — surfaced, never
                // silently dropped.
                submissionFailureText = String(describing: error)
            }
        }
    }

    /// The modal's Cancel (issue #29): un-ends the session via
    /// `AppModel.cancelEndOfSession()` — the retained result is discarded
    /// as a log (nothing is appended) and the session is restored from the
    /// captured end-instant snapshot (the #13 restore path; running-at-end
    /// → re-anchored running, paused-at-end → restored paused). The phase
    /// returns to `.timerView` and this sheet leaves with the app-shell
    /// branch swap. Esc is deliberately NOT wired to this (pinned: keep
    /// Esc disabled — the sheet's `interactiveDismissDisabled` stays and no
    /// `.cancelAction` shortcut is added); this button is the affordance.
    /// The only possible throw (`restore`'s `.sessionAlreadyActive`) is
    /// impossible from this state (the engine has been idle since confirm)
    /// but is surfaced inline, never swallowed.
    private func cancel() {
        submissionFailureText = nil
        do {
            try model.cancelEndOfSession()
        } catch {
            submissionFailureText = String(describing: error)
        }
    }

    /// The confirmed destructive action of the #27 escape hatch: drops the
    /// in-memory result via `AppModel.discardEndOfSession()` — the honest
    /// §18 loss (the unsubmitted session is the only copy; the snapshot was
    /// already cleared at confirm) — and returns to Tasks. Nothing is
    /// written to any log.
    private func discard() {
        submissionFailureText = nil
        model.discardEndOfSession()
    }
}
