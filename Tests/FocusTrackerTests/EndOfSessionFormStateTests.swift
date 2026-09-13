import XCTest
@testable import FocusTracker

/// Pure validation + composition tests for the #22 end-of-session form
/// state (issue #22 criteria 8–9): Yes/No + focus 1–5 + energy 1–5 are
/// required (notes optional), and `makeLog(from:)` composes the §13 log
/// purely — seven timing fields verbatim from the result, the modal's
/// answers for the rest, notes nil-when-trimmed-empty. No I/O, no clock.
final class EndOfSessionFormStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeResult(
        focused: Int = 25, paused: Int = 5, pauseCount: Int = 1
    ) -> FocusSessionResult {
        FocusSessionResult(
            sessionID: UUID(uuidString: "d1e2f3a4-b5c6-4d7e-8f90-1a2b3c4d5e6f")!,
            taskID: UUID(uuidString: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            endedAt: Date(timeIntervalSinceReferenceDate: 800_002_100),
            focusedDuration: focused,
            pauseCount: pauseCount,
            pausedDuration: paused)
    }

    private func makeForm(
        completed: EndOfSessionFormState.CompletedChoice? = .yes,
        focus: Int? = 4, energy: Int? = 3, notes: String = ""
    ) -> EndOfSessionFormState {
        var form = EndOfSessionFormState()
        form.completedChoice = completed
        form.focusRating = focus
        form.energyRating = energy
        form.notes = notes
        return form
    }

    // MARK: - Validation (issue criterion 8: pure, tested)

    func testBlankFormIsNotSubmittable() {
        XCTAssertFalse(EndOfSessionFormState().isSubmittable)
    }

    func testEveryChoiceMissingAloneBlocksSubmission() {
        XCTAssertFalse(
            makeForm(completed: nil).isSubmittable, "Yes/No is required")
        XCTAssertFalse(
            makeForm(focus: nil).isSubmittable, "focus is required")
        XCTAssertFalse(
            makeForm(energy: nil).isSubmittable, "energy is required")
        // Notes never block: optional (§12.4), even when empty.
        XCTAssertTrue(makeForm(notes: "").isSubmittable)
    }

    func testRatingDomainIsOneThroughFive() {
        for value in EndOfSessionFormState.ratingRange {
            XCTAssertTrue(
                EndOfSessionFormState.isValidRating(value),
                "\(value) is inside the domain")
            XCTAssertTrue(
                makeForm(focus: value, energy: value).isSubmittable,
                "both ratings at \(value) submit")
        }
        for value in [0, -1, 6, Int.max] {
            XCTAssertFalse(
                EndOfSessionFormState.isValidRating(value),
                "\(value) is outside the domain")
        }
        XCTAssertFalse(
            EndOfSessionFormState.isValidRating(nil), "unchosen is invalid")
    }

    func testNoAnswerIsAsSubmittableAsYes() {
        XCTAssertTrue(makeForm(completed: .no).isSubmittable)
        XCTAssertTrue(makeForm(completed: .yes).isSubmittable)
    }

    // MARK: - Log composition (issue criterion 9: pure)

    func testMakeLogComposesAllSection13FieldsFromResultAndAnswers() throws {
        let result = makeResult()
        let log = try makeForm(
            completed: .yes, focus: 4, energy: 2, notes: "Deep work."
        ).makeLog(from: result)

        // The seven timing fields come verbatim from the result.
        XCTAssertEqual(log.sessionID, result.sessionID)
        XCTAssertEqual(log.taskID, result.taskID)
        XCTAssertEqual(log.startedAt, result.startedAt)
        XCTAssertEqual(log.endedAt, result.endedAt)
        XCTAssertEqual(log.focusedDuration, result.focusedDuration)
        XCTAssertEqual(log.pauseCount, result.pauseCount)
        XCTAssertEqual(log.pausedDuration, result.pausedDuration)
        // The modal's answers.
        XCTAssertEqual(log.focusRating, 4)
        XCTAssertEqual(log.energyRating, 2)
        XCTAssertEqual(log.taskCompleted, true)
        XCTAssertEqual(log.notes, "Deep work.")
    }

    func testMakeLogNoAnswerComposesTaskCompletedFalse() throws {
        let log = try makeForm(completed: .no).makeLog(from: makeResult())
        XCTAssertEqual(log.taskCompleted, false)
    }

    func testMakeLogNotesAreTrimmedAndNilWhenEmpty() throws {
        XCTAssertEqual(
            try makeForm(notes: "  spaced  ").makeLog(from: makeResult()).notes,
            "spaced", "notes are trimmed")
        XCTAssertNil(
            try makeForm(notes: "").makeLog(from: makeResult()).notes,
            "empty notes compose as nil")
        XCTAssertNil(
            try makeForm(notes: "   \n\t ").makeLog(from: makeResult()).notes,
            "whitespace-only notes compose as nil")
    }
}
