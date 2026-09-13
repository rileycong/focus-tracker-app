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
    /// identity/timestamp fields come verbatim from the engine's
    /// `FocusSessionResult`, `task_completed` from the Yes/No answer, the
    /// ratings from the chosen levels, and `notes` from the free-text field
    /// — `nil` when trimmed-empty (the file omits the key, matching the #11
    /// optional-field convention).
    ///
    /// # Whole-minute reconciliation (issue #27, PINNED formula)
    /// The three duration fields do NOT pass through verbatim: the engine's
    /// independent nearest-minute rounding can drift the minute sum from the
    /// wall-clock span (the #27 repro: 66 s span, focused 55 s → 1 min,
    /// paused 11 s → 0 min — and 1 + 0 ≠ any whole-minute reading of 66 s
    /// under #11's original exact-second check), which made the append
    /// validation fail and trapped the modal. The composition reconciles so
    /// the #11 append check passes for ANY session (with #27's amended
    /// minute-granularity check, see `DailyLogCodec`):
    ///
    /// - `span_min = nearest((ended_at − started_at) / 60)` — from the
    ///   WALL-CLOCK timestamps, i.e. exactly the span the #11 check reads;
    /// - `paused_min = min(nearest(paused_seconds / 60), span_min)` — the
    ///   engine's `pausedDuration` already IS `nearest(paused_seconds / 60)`
    ///   (the #12 pinned rounding rule), so `min(result.pausedDuration,
    ///   span_min)` implements this verbatim. The clamp is a no-op whenever
    ///   the wall span ≥ the monotonic paused sum (always true absent a
    ///   mid-session wall-clock change; #12 pins `ended_at − started_at` as
    ///   the timestamp authority) and is what guarantees `focused_min ≥ 0`
    ///   unconditionally;
    /// - `focused_min = span_min − paused_min` — still excludes paused time
    ///   in the rounded form (§13 semantics).
    ///
    /// **Documented drift bound:** reconciled `focused_min` can differ from
    /// `nearest(focused_seconds / 60)` by at most 1 minute — the price of
    /// the exact invariant (two independent nearest roundings can drift the
    /// sum by ±1; reconciliation spends that ±1 on `focused_min` only).
    /// Second-precision engine values are unchanged — the #12 engine keeps
    /// returning honest whole-minute fields and is NOT touched here; the
    /// reconciliation lives entirely in this composition layer.
    ///
    /// - Precondition: `isSubmittable`. The model re-checks it before
    ///   calling and the modal's submit button is enabled only on a complete
    ///   form, so a violation is a caller contract bug — never a runtime
    ///   condition to mask with fabricated defaults.
    func makeLog(from result: FocusSessionResult) -> FocusSessionLog {
        precondition(
            isSubmittable, "makeLog requires a submittable end-of-session form")
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // The #27 reconciliation (pinned formula, documented above).
        let spanMinutes = Self.nearestMinute(
            fromSeconds: result.endedAt.timeIntervalSince(result.startedAt))
        let pausedMinutes = min(result.pausedDuration, spanMinutes)
        let focusedMinutes = spanMinutes - pausedMinutes
        return FocusSessionLog(
            sessionID: result.sessionID,
            taskID: result.taskID,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            focusedDuration: focusedMinutes,
            pauseCount: result.pauseCount,
            pausedDuration: pausedMinutes,
            focusRating: focusRating ?? 0,
            energyRating: energyRating ?? 0,
            taskCompleted: completedChoice == .yes,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes)
    }

    /// Pinned nearest-minute rounding, half away from zero — the engine's
    /// own #12 rounding rule, mirrored here so the composition derives
    /// `span_min` from the wall-clock span with the exact same rule.
    static func nearestMinute(fromSeconds seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded(.toNearestOrAwayFromZero))
    }
}
