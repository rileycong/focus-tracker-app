import SwiftUI

/// The blocking end-of-session modal (issue #22, PRD §12): shown over the
/// full timer exactly while `AppPhase.endingSession` is active — presented
/// by the app shell (the ONE presentation path; this view never presents
/// itself). Submission is REQUIRED (§12.5): interactive dismissal is
/// disabled and the phase only leaves `.endingSession` through
/// `AppModel.submitEndOfSession`.
///
/// # Fields (§12.1–§12.4, exact)
/// **Completed task?** Yes/No selectable buttons — no default selected, the
/// user must choose; **Focus level** and **Energy level** 1–5 selectable
/// buttons; **Notes** free text — optional, empty allowed. All validation
/// lives in the pure `EndOfSessionFormState` (`isSubmittable`), which the
/// submit button binds to; this view holds no logic of its own.
///
/// # Outcomes
/// - `.success` — the phase moved to `.tasksView`; the sheet leaves with the
///   app-shell branch swap.
/// - `.logAppendFailed` — nothing was written; the ending state is retained
///   (the phase is untouched, the sheet stays up) and the failure is
///   surfaced inline for retry.
/// - `.completionFailedAfterLog` — the documented partial outcome: the
///   session IS logged, the status is NOT updated; the app returns to Tasks,
///   where the user can complete the task manually in the UI.
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
                Spacer()
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
}
