import XCTest
@testable import FocusTracker

/// Pure validation + composition tests for the #22 end-of-session form
/// state (issue #22 criteria 8–9): Yes/No + focus 1–5 + energy 1–5 are
/// required (notes optional), and `makeLog(from:)` composes the §13 log
/// purely — identity/timestamp fields verbatim from the result, the modal's
/// answers for the rest, notes nil-when-trimmed-empty, and (issue #27) the
/// whole-minute reconciliation of the three duration fields. No I/O, no
/// clock.
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

        // Identity + timestamps come verbatim from the result.
        XCTAssertEqual(log.sessionID, result.sessionID)
        XCTAssertEqual(log.taskID, result.taskID)
        XCTAssertEqual(log.startedAt, result.startedAt)
        XCTAssertEqual(log.endedAt, result.endedAt)
        XCTAssertEqual(log.pauseCount, result.pauseCount)
        // The duration fields are the #27 reconciliation of the result:
        // span 2100 s → span_min 35; paused_min min(5, 35) = 5;
        // focused_min 35 − 5 = 30 (the result's own 25 + 5 here is the
        // artificially inconsistent shape the reconciliation exists for).
        XCTAssertEqual(log.focusedDuration, 30)
        XCTAssertEqual(log.pausedDuration, 5)
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

    // MARK: - Whole-minute reconciliation (issue #27 criterion 1)

    /// Test-local mirror of the engine's pinned rounding rule (nearest
    /// minute, half away from zero — #12): `FocusSessionResult` carries
    /// whole minutes, so a fixture result is built the way the engine would
    /// produce it from the second-precision telemetry.
    private static func nearestMinute(_ seconds: Int) -> Int {
        Int((Double(seconds) / 60).rounded(.toNearestOrAwayFromZero))
    }

    /// Builds a result exactly as the engine would report the given
    /// second-precision telemetry: minute fields nearest-rounded from the
    /// seconds, timestamps spanning exactly `spanSeconds` of wall clock.
    private func makeEngineResult(
        focusedSeconds: Int, pausedSeconds: Int, spanSeconds: Int
    ) -> FocusSessionResult {
        FocusSessionResult(
            sessionID: UUID(uuidString: "d1e2f3a4-b5c6-4d7e-8f90-1a2b3c4d5e6f")!,
            taskID: UUID(uuidString: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            endedAt: Date(
                timeIntervalSinceReferenceDate: 800_000_000 + Double(spanSeconds)),
            focusedDuration: Self.nearestMinute(focusedSeconds),
            pauseCount: pausedSeconds > 0 ? 1 : 0,
            pausedDuration: Self.nearestMinute(pausedSeconds))
    }

    /// The pinned reconciliation cases (issue criterion 4): each is
    /// "(focused s, paused s, span s) → log focused/paused minutes", with
    /// the #27-amended append check accepting every composed log.
    func testReconciliationPinnedCases() throws {
        let form = makeForm()
        let cases: [(focused: Int, paused: Int, span: Int, logFocused: Int, logPaused: Int)] = [
            // The #27 repro: 66 s span, 55 s focus, 11 s pause → 1/0.
            (55, 11, 66, 1, 0),
            // Half-away-from-zero rounds a 30 s pause to 1 min, so
            // reconciliation yields focused 0 (1/1 would violate the
            // invariant) — exactly the drift the fix removes.
            (30, 30, 60, 0, 1),
            (59, 1, 60, 1, 0),
            (61, 59, 120, 1, 1),
            // 34 s paused of a 35 s span: focused 1 s → 0, paused 34 s → 1.
            (1, 34, 35, 0, 1),
            // Sub-minute span, no pause.
            (45, 0, 45, 1, 0),
        ]
        for testCase in cases {
            let result = makeEngineResult(
                focusedSeconds: testCase.focused, pausedSeconds: testCase.paused,
                spanSeconds: testCase.span)
            let log = try form.makeLog(from: result)
            XCTAssertEqual(
                log.focusedDuration, testCase.logFocused,
                "focused for \(testCase)")
            XCTAssertEqual(
                log.pausedDuration, testCase.logPaused,
                "paused for \(testCase)")
            // The composed log always satisfies the #11 invariant at the
            // #27 minute granularity — the append check accepts it.
            XCTAssertNil(
                DailyLogCodec.appendValidationFailure(for: log),
                "append accepts the reconciled log for \(testCase)")
        }
    }

    /// Bounded property loop (issue #27 criterion 4, sharpened): a SEEDED
    /// deterministic RNG (reproducible failures — no unseeded randomness in
    /// the suite), 600 iterations, span ∈ 0…7200 s, paused ∈ 0…span,
    /// focused = span − paused. Per iteration the composed log must satisfy
    /// the invariant `nearest(span/60) == focused_min + paused_min`,
    /// `focused_min ≥ 0`, the drift bound
    /// `|focused_min − nearest(focused_seconds/60)| ≤ 1`, and the #27
    /// append check must accept it.
    func testReconciliationPropertyOverSeededRandomSessions() throws {
        // SplitMix64 with a fixed seed — deterministic across runs/machines.
        var state: UInt64 = 0x0027_0000_0000_0001
        func nextRandom() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let form = makeForm()
        let iterations = 600
        for index in 0..<iterations {
            let spanSeconds = Int(nextRandom() % 7201)
            let pausedSeconds = Int(nextRandom() % UInt64(spanSeconds + 1))
            let focusedSeconds = spanSeconds - pausedSeconds
            let result = makeEngineResult(
                focusedSeconds: focusedSeconds, pausedSeconds: pausedSeconds,
                spanSeconds: spanSeconds)
            let log = try form.makeLog(from: result)

            // 1. The #11 invariant at the fields' (whole-minute) granularity.
            XCTAssertEqual(
                Self.nearestMinute(spanSeconds),
                log.focusedDuration + log.pausedDuration,
                "invariant for iteration \(index): span \(spanSeconds) s, "
                    + "paused \(pausedSeconds) s")
            // 2. focused_min ≥ 0 unconditionally.
            XCTAssertGreaterThanOrEqual(
                log.focusedDuration, 0,
                "focused ≥ 0 for iteration \(index)")
            // 3. The documented drift bound.
            XCTAssertLessThanOrEqual(
                abs(log.focusedDuration - Self.nearestMinute(focusedSeconds)), 1,
                "drift bound for iteration \(index)")
            // 4. The #27-amended append check accepts the composition.
            XCTAssertNil(
                DailyLogCodec.appendValidationFailure(for: log),
                "append accepts iteration \(index)")
        }
    }
}
