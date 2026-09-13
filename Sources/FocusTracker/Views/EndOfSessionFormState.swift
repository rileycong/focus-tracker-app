import Foundation

/// The pure form state of the #22 end-of-session modal (PRD §12): everything
/// the modal edits, plus the §13 `FocusSessionLog` composition. Mirrors the
/// `TaskFormState` (#16) / `SubtaskFormState` (#17) house patterns; no I/O,
/// no SwiftUI — fully unit-testable (issue #22: "pure validated form state
/// type, tested").
struct EndOfSessionFormState: Equatable, Sendable {

    /// The §12.1 "Completed task?" answer. Modeled as a dedicated choice
    /// instead of a plain `Bool` because there is deliberately NO default —
    /// the user must choose Yes or No before submission is enabled (issue
    /// criterion 7).
    enum CompletedChoice: Equatable, Sendable {
        case yes
        case no
    }

    // MARK: - Editable fields

    /// The completion answer; `nil` until the user picks Yes or No.
    var completedChoice: CompletedChoice?
    /// The §12.2 focus level; `nil` until chosen, domain 1–5.
    var focusRating: Int?
    /// The §12.3 energy level; `nil` until chosen, domain 1–5.
    var energyRating: Int?
    /// The §12.4 notes free text. OPTIONAL (empty allowed, §12.4: no
    /// structured prompt); a trimmed-empty value composes as `nil` in the
    /// log (issue criterion 9).
    var notes: String = ""

    // MARK: - Validation

    /// The §12 domain rating range (both ratings are 1–5 selectable buttons).
    static let ratingRange: ClosedRange<Int> = 1...5

    /// Whether `value` is a valid rating: inside the domain 1–5. `nil`
    /// (not chosen yet) is invalid.
    static func isValidRating(_ value: Int?) -> Bool {
        guard let value else { return false }
        return ratingRange.contains(value)
    }

    /// Whether the form can submit (§12.5): Yes/No **and** focus **and**
    /// energy are all chosen — notes excepted (optional). Pure, tested
    /// logic; the modal's submit button binds to this (issue criterion 8).
    var isSubmittable: Bool {
        completedChoice != nil
            && Self.isValidRating(focusRating)
            && Self.isValidRating(energyRating)
    }

    // MARK: - Mapping form state → FocusSessionLog

    /// Composes the §13 log (issue #22 criterion 9, PRD §13) purely: the
    /// seven timing fields come verbatim from the engine's
    /// `FocusSessionResult`, `task_completed` from the Yes/No answer, the
    /// ratings from the chosen levels, and `notes` from the free-text field
    /// — `nil` when trimmed-empty (the file omits the key, matching the #11
    /// optional-field convention).
    ///
    /// - Precondition: `isSubmittable`. The model re-checks it before
    ///   calling and the modal's submit button is enabled only on a complete
    ///   form, so a violation is a caller contract bug — never a runtime
    ///   condition to mask with fabricated defaults.
    func makeLog(from result: FocusSessionResult) -> FocusSessionLog {
        precondition(
            isSubmittable, "makeLog requires a submittable end-of-session form")
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return FocusSessionLog(
            sessionID: result.sessionID,
            taskID: result.taskID,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            focusedDuration: result.focusedDuration,
            pauseCount: result.pauseCount,
            pausedDuration: result.pausedDuration,
            focusRating: focusRating ?? 0,
            energyRating: energyRating ?? 0,
            taskCompleted: completedChoice == .yes,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes)
    }
}
