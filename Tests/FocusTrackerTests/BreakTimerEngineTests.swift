import XCTest
@testable import FocusTracker

/// Tests for the #23 break engine (`BreakTimerEngine`), driven entirely by
/// an injected fake clock (the same seam shape as the #12 engine tests):
/// default/custom durations, mid-countdown derived values, the pinned
/// expiry clamps, the early-end and post-expiry `end()` results with their
/// invariant-consistent timestamps, and the typed `Equatable` errors —
/// every error assertion exact-case, never string matching.
final class BreakTimerEngineTests: XCTestCase {

    // MARK: - Fake clock

    /// Test clock: monotonic and wall-clock readings are independent knobs
    /// (same shape as the #12 tests' fake). `advance(by:)` is the normal
    /// path; `jumpWallClock` models wall-clock change while monotonic time
    /// keeps flowing.
    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(by seconds: TimeInterval) {
            monotonicSeconds += seconds
            wallClockNow = wallClockNow.addingTimeInterval(seconds)
        }

        func jumpWallClock(by seconds: TimeInterval) {
            wallClockNow = wallClockNow.addingTimeInterval(seconds)
        }
    }

    // MARK: - Helpers

    private func makeEngine() -> (engine: BreakTimerEngine, clock: FakeClock) {
        let clock = FakeClock()
        return (BreakTimerEngine(clock: clock), clock)
    }

    private func startedEngine(
        duration: TimeInterval = BreakTimerEngine.defaultDurationSeconds
    ) -> (engine: BreakTimerEngine, clock: FakeClock) {
        let clock = FakeClock()
        var engine = BreakTimerEngine(clock: clock)
        try? engine.start(duration: duration)
        return (engine, clock)
    }

    // MARK: - Start (issue criterion 22: default 5 minutes + custom)

    func testPinnedDefaultDurationIsFiveMinutes() throws {
        var (engine, clock) = startedEngine()

        XCTAssertTrue(engine.isActive)
        XCTAssertEqual(BreakTimerEngine.defaultDurationSeconds, 300)
        XCTAssertEqual(engine.configuredDurationSeconds, 300)
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 300)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 0, accuracy: 1e-12)
        XCTAssertFalse(engine.isExpired(at: clock.monotonicSeconds))
        // The wall-clock reading at start is carried for the log.
        let result = try engine.end()
        XCTAssertEqual(result.startedAt, FakeClock().wallClockNow, "wall clock at start")
    }

    func testCustomDurationOverridesDefault() throws {
        var (engine, clock) = startedEngine(duration: 7 * 60 + 15)

        XCTAssertTrue(engine.isActive)
        XCTAssertEqual(engine.configuredDurationSeconds, 435)
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 435)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 0, accuracy: 1e-12)
    }

    func testStartAssignsItsOwnBreakID() throws {
        var (engine, _) = makeEngine()
        try engine.start()
        let first = try engine.end()
        try engine.start()
        let second = try engine.end()

        XCTAssertNotEqual(first.breakID, second.breakID, "each break has its own UUID")
    }

    // MARK: - Mid-countdown derived values (issue criterion 22)

    func testMidCountdownRemainingProgressAndNotExpired() throws {
        var (engine, clock) = startedEngine(duration: 600)
        clock.advance(by: 150)

        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 450)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 0.25, accuracy: 1e-12)
        XCTAssertFalse(engine.isExpired(at: clock.monotonicSeconds))

        // Sub-second remaining floors: the countdown never overstates.
        clock.advance(by: 0.4)
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 449)
    }

    // MARK: - Expiry clamps (issue criteria 9 + 22)

    func testExpiryClampsRemainingAndProgressAndReportsPurely() throws {
        var (engine, clock) = startedEngine(duration: 300)
        clock.advance(by: 300)

        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 0)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 1, accuracy: 1e-12)
        XCTAssertTrue(engine.isExpired(at: clock.monotonicSeconds))

        // Time past expiry changes nothing in the display values (no
        // overrun is ever shown) and the break stays active — no auto-end
        // (criterion 9: expiry reports done, no callbacks, no auto-anything).
        clock.advance(by: 120)
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 0)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 1, accuracy: 1e-12)
        XCTAssertTrue(engine.isExpired(at: clock.monotonicSeconds))
        XCTAssertTrue(engine.isActive, "the break screen stays up until the user acts")
    }

    func testIdleDerivedValuesAreNilZeroFalse() {
        var (engine, clock) = makeEngine()

        XCTAssertFalse(engine.isActive)
        XCTAssertNil(engine.remainingSeconds(at: clock.monotonicSeconds), "idle ≠ expired")
        XCTAssertNil(engine.configuredDurationSeconds)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 0, accuracy: 1e-12)
        XCTAssertFalse(engine.isExpired(at: clock.monotonicSeconds))
    }

    // MARK: - Early end (issue criterion 10: the shorter ACTUAL duration)

    func testEndEarlyReturnsActualShorterWholeMinuteDuration() throws {
        var (engine, clock) = startedEngine(duration: 300)
        clock.advance(by: 120)

        let result = try engine.end()

        XCTAssertEqual(result.duration, 2, "nearest-minute rounding of 120 s")
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt), 120, accuracy: 1e-9,
            "ended − started == duration exactly (the #11 append invariant)")
        XCTAssertFalse(engine.isActive, "end closes the lifecycle")
    }

    func testEndEarlyNonWholeMinuteReconcilesEndedAtToStartedPlusDuration() throws {
        // 100 s of a 5-minute break: nearest-minute = 2 minutes; ended_at
        // reconciles to started_at + 120 s so the #11 append invariant holds
        // EXACTLY (criterion 10).
        var (engine, clock) = startedEngine(duration: 300)
        clock.advance(by: 100)

        let result = try engine.end()

        XCTAssertEqual(result.duration, 2)
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt), 120, accuracy: 1e-9)
    }

    func testSubMinuteEarlyEndReconcilesEndedAtToStartedPlusZeroDuration() throws {
        // The issue's pinned sub-minute example: a 29 s break logs 0 minutes
        // with ended_at == started_at exactly.
        var (engine, clock) = startedEngine(duration: 300)
        clock.advance(by: 29)

        let result = try engine.end()

        XCTAssertEqual(result.duration, 0)
        XCTAssertEqual(result.endedAt, result.startedAt)
    }

    func testWallClockChangeDoesNotLeakIntoEarlyEndMath() throws {
        // Monotonic readings drive ALL duration math (pinned clock rule);
        // a wall-clock jump mid-break changes neither the duration nor the
        // reconciled span.
        var (engine, clock) = startedEngine(duration: 300)
        clock.advance(by: 60)
        clock.jumpWallClock(by: 3_600)

        let result = try engine.end()

        XCTAssertEqual(result.duration, 1)
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt), 60, accuracy: 1e-9)
    }

    // MARK: - Post-expiry end (issue criteria 10 + 22: clamped + invariant)

    func testEndAfterExpiryClampsToConfiguredDurationWithExpiryTimestamp() throws {
        var (engine, clock) = startedEngine(duration: 300)
        clock.advance(by: 400)

        let result = try engine.end()

        // §14.4: no overrun tracking — clamped to the configured 5 minutes.
        XCTAssertEqual(result.duration, 5)
        // The expiry instant: for the whole-minute configured duration the
        // reconciled ended_at IS started_at + 300 s — the invariant holds
        // EXACTLY (criterion 10's pinned pairing).
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt), 300, accuracy: 1e-9)
    }

    func testEndLongAfterExpiryStillClampsExactly() throws {
        var (engine, clock) = startedEngine(duration: 60)
        clock.advance(by: 7_257)  // over two hours past a 1-minute break

        let result = try engine.end()

        XCTAssertEqual(result.duration, 1)
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt), 60, accuracy: 1e-9)
    }

    // MARK: - Typed errors (issue criterion 11 + 22)

    func testDoubleStartThrowsBreakAlreadyActive() throws {
        var (engine, clock) = makeEngine()
        try engine.start(duration: 60)
        clock.advance(by: 10)

        XCTAssertThrowsError(try engine.start(duration: 60)) { error in
            XCTAssertEqual(error as? BreakTimerError, .breakAlreadyActive)
        }
        // The original break is untouched by the refused start.
        XCTAssertEqual(engine.configuredDurationSeconds, 60)
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 50)
    }

    func testEndWithoutStartThrowsNoActiveBreak() throws {
        var (engine, _) = makeEngine()

        XCTAssertThrowsError(try engine.end()) { error in
            XCTAssertEqual(error as? BreakTimerError, .noActiveBreak)
        }
    }

    func testEndAfterEndThrowsNoActiveBreakAndEngineIsReusable() throws {
        var (engine, clock) = startedEngine(duration: 60)
        clock.advance(by: 30)
        _ = try engine.end()

        XCTAssertThrowsError(try engine.end()) { error in
            XCTAssertEqual(error as? BreakTimerError, .noActiveBreak)
        }

        // Reusable for a fresh break (new ID) after the lifecycle closes.
        try engine.start(duration: 120)
        XCTAssertTrue(engine.isActive)
        clock.advance(by: 60)
        let second = try engine.end()
        XCTAssertEqual(second.duration, 1)
    }
}
