import XCTest
@testable import FocusTracker

/// Tests for the #12 focus-session engine (`FocusSessionEngine`), driven
/// entirely by an injected fake clock whose monotonic and wall-clock readings
/// advance independently — that is what makes the exact-cycle math, the
/// pause-gap exclusion and the clock-change-safety assertions deterministic.
/// Every error assertion is exact-case (`Equatable`), never string matching.
final class FocusSessionEngineTests: XCTestCase {

    // MARK: - Fake clock

    /// Test clock: monotonic and wall-clock readings are independent knobs.
    /// `advance(by:)` is the normal path (both move together, like real
    /// time); `jumpWallClock` models wall-clock change while monotonic time
    /// keeps flowing (sleep/NTP scenarios).
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

    private let taskID = UUID()

    private func makeEngine() -> (engine: FocusSessionEngine, clock: FakeClock) {
        let clock = FakeClock()
        return (FocusSessionEngine(clock: clock), clock)
    }

    private func startedEngine(
        duration: TimeInterval = FocusSessionEngine.defaultDurationSeconds
    ) -> (engine: FocusSessionEngine, clock: FakeClock) {
        let clock = FakeClock()
        var engine = FocusSessionEngine(clock: clock)
        try? engine.start(taskID: taskID, duration: duration)
        return (engine, clock)
    }

    // MARK: - Start basics (PRD §9.1, §9.2)

    func testDefaultDurationIsTwentyFiveMinutes() throws {
        let (engine, clock) = startedEngine()

        XCTAssertTrue(engine.isActive)
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 1500)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 0, accuracy: 1e-12)
        XCTAssertFalse(engine.isExpired(at: clock.monotonicSeconds))
    }

    func testConfiguredDurationOverridesDefault() throws {
        let (engine, clock) = startedEngine(duration: 10 * 60)

        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 600)
    }

    func testStartAssignsSessionIDTaskIDAndWallClockTimestamps() throws {
        var (engine, clock) = makeEngine()
        try engine.start(taskID: taskID)

        clock.advance(by: 60)
        let result = try engine.end()

        XCTAssertEqual(result.taskID, taskID)
        XCTAssertNotEqual(result.sessionID, taskID, "session identity is its own UUID")
        XCTAssertEqual(result.startedAt, FakeClock().wallClockNow, "wall clock at start")
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt), 60, accuracy: 1e-9)
        XCTAssertFalse(engine.isActive, "end closes the lifecycle")
    }

    func testSessionIDsDifferAcrossSessions() throws {
        var (engine, _) = startedEngine()
        let first = try engine.end()
        try engine.start(taskID: taskID)
        let second = try engine.end()

        XCTAssertNotEqual(first.sessionID, second.sessionID)
    }

    // MARK: - Invalid transitions: typed, Equatable, exact cases

    func testStartTwiceThrowsSessionAlreadyActive() throws {
        var (engine, clock) = startedEngine()

        XCTAssertThrowsError(try engine.start(taskID: UUID())) { error in
            XCTAssertEqual(error as? FocusSessionError, .sessionAlreadyActive)
        }
        // The first lifecycle is untouched by the refused start:
        XCTAssertTrue(engine.isActive)
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 1500)
    }

    func testOperationsWithoutStartThrowNoActiveSession() throws {
        var (engine, _) = makeEngine()

        XCTAssertThrowsError(try engine.pause()) { error in
            XCTAssertEqual(error as? FocusSessionError, .noActiveSession)
        }
        XCTAssertThrowsError(try engine.resume()) { error in
            XCTAssertEqual(error as? FocusSessionError, .noActiveSession)
        }
        XCTAssertThrowsError(try engine.end()) { error in
            XCTAssertEqual(error as? FocusSessionError, .noActiveSession)
        }
        XCTAssertFalse(engine.isActive)
    }

    func testOperationsAfterEndThrowNoActiveSessionAgain() throws {
        var (engine, _) = startedEngine()
        _ = try engine.end()

        XCTAssertThrowsError(try engine.pause()) { error in
            XCTAssertEqual(error as? FocusSessionError, .noActiveSession)
        }
        XCTAssertThrowsError(try engine.end()) { error in
            XCTAssertEqual(error as? FocusSessionError, .noActiveSession)
        }
    }

    func testPauseTwiceThrowsAlreadyPaused() throws {
        var (engine, _) = startedEngine()
        try engine.pause()

        XCTAssertThrowsError(try engine.pause()) { error in
            XCTAssertEqual(error as? FocusSessionError, .alreadyPaused)
        }
    }

    func testResumeWhileRunningThrowsResumeWhileRunning() throws {
        var (engine, _) = startedEngine()

        XCTAssertThrowsError(try engine.resume()) { error in
            XCTAssertEqual(error as? FocusSessionError, .resumeWhileRunning)
        }
    }

    func testErrorCasesAreDistinctTypedValues() throws {
        XCTAssertEqual(FocusSessionError.sessionAlreadyActive, .sessionAlreadyActive)
        XCTAssertNotEqual(FocusSessionError.sessionAlreadyActive, .noActiveSession)
        XCTAssertNotEqual(FocusSessionError.noActiveSession, .alreadyPaused)
        XCTAssertNotEqual(FocusSessionError.alreadyPaused, .resumeWhileRunning)
        XCTAssertNotEqual(FocusSessionError.resumeWhileRunning, .sessionAlreadyActive)
    }

    // MARK: - Exact cycle math (pinned example: 10 / 5 / 15)

    func testPinnedCycleRun10Pause5Run15ExactMath() throws {
        var (engine, clock) = startedEngine(duration: 3600)

        clock.advance(by: 600)  // run 10 min
        try engine.pause()
        clock.advance(by: 300)  // pause 5 min
        try engine.resume()
        clock.advance(by: 900)  // run 15 min

        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 2100)
        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 25)
        XCTAssertEqual(result.pausedDuration, 5)
        XCTAssertEqual(result.pauseCount, 1)
        XCTAssertEqual(result.taskID, taskID)
        // The #11 append invariant holds exactly for whole-minute spans:
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt),
            Double((result.focusedDuration + result.pausedDuration) * 60),
            accuracy: 1e-9)
    }

    // MARK: - Multiple cycles

    func testMultiplePauseResumeCyclesAccumulateExactly() throws {
        var (engine, clock) = startedEngine(duration: 3600)

        clock.advance(by: 300)  // run 5
        try engine.pause()
        clock.advance(by: 120)  // pause 2
        try engine.resume()
        clock.advance(by: 180)  // run 3
        try engine.pause()
        clock.advance(by: 240)  // pause 4
        try engine.resume()
        clock.advance(by: 420)  // run 7

        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 15)
        XCTAssertEqual(result.pausedDuration, 6)
        XCTAssertEqual(result.pauseCount, 2)
    }

    // MARK: - Ending early

    func testEndEarlyBeforeConfiguredDuration() throws {
        var (engine, clock) = startedEngine()  // 25 min configured

        clock.advance(by: 600)  // run 10 min
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 900)
        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 10)
        XCTAssertEqual(result.pausedDuration, 0)
        XCTAssertEqual(result.pauseCount, 0)
    }

    // MARK: - Whole-minute rounding (pinned: nearest, half away from zero)

    func testFocusedRoundsToNearestMinute() throws {
        var (engine, clock) = startedEngine()
        clock.advance(by: 24 * 60 + 30)  // 24 min 30 s → exactly half → up
        XCTAssertEqual(try engine.end().focusedDuration, 25)

        var (engine2, clock2) = startedEngine()
        clock2.advance(by: 24 * 60 + 29)  // 24 min 29 s → down
        XCTAssertEqual(try engine2.end().focusedDuration, 24)
    }

    func testPausedRoundsToNearestMinute() throws {
        var (engine, clock) = startedEngine(duration: 3600)
        try engine.pause()
        clock.advance(by: 59)  // 59 s paused → rounds to 1
        try engine.resume()
        let result = try engine.end()
        XCTAssertEqual(result.pausedDuration, 1)

        var (engine2, clock2) = startedEngine(duration: 3600)
        try engine2.pause()
        clock2.advance(by: 29)  // 29 s paused → rounds to 0
        try engine2.resume()
        XCTAssertEqual(try engine2.end().pausedDuration, 0)
    }

    func testSecondPrecisionSumsAcrossManySmallAdvances() throws {
        var (engine, clock) = startedEngine(duration: 3600)

        for _ in 0..<60 {  // 60 × 1.5 s = 90 s = 1.5 min → rounds to 2
            clock.advance(by: 1.5)
        }
        XCTAssertEqual(try engine.end().focusedDuration, 2)
    }

    // MARK: - Derived values: remaining / progress math

    func testRemainingAndProgressMathMidSession() throws {
        let (engine, clock) = startedEngine()  // 25 min

        clock.advance(by: 600)  // 10 min focused
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 900)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 0.4, accuracy: 1e-12)
        XCTAssertFalse(engine.isExpired(at: clock.monotonicSeconds))
    }

    func testRemainingFreezesWhilePaused() throws {
        var (engine, clock) = startedEngine()

        clock.advance(by: 600)
        try engine.pause()
        clock.advance(by: 420)  // 7 min paused — remaining must not move

        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 900)
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 0.4, accuracy: 1e-12)

        try engine.resume()
        clock.advance(by: 60)
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 840)
    }

    func testIdleEngineReportsNilRemainingZeroProgressNoExpiry() {
        let (engine, clock) = makeEngine()

        XCTAssertFalse(engine.isActive)
        XCTAssertNil(engine.remainingSeconds(at: clock.monotonicSeconds))
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 0, accuracy: 1e-12)
        XCTAssertEqual(engine.focusedSeconds(at: clock.monotonicSeconds), 0, accuracy: 1e-12)
        XCTAssertFalse(engine.isExpired(at: clock.monotonicSeconds))
    }

    // MARK: - Expiry: clamp remaining, keep accumulating, no auto-end

    func testExpiryClampsRemainingAtZeroWhileFocusedAccumulates() throws {
        var (engine, clock) = startedEngine()  // 25 min

        clock.advance(by: 1500)  // exactly at the boundary
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 0)
        XCTAssertTrue(engine.isExpired(at: clock.monotonicSeconds))
        XCTAssertTrue(engine.isActive, "no auto-end at expiry")

        clock.advance(by: 600)  // 10 more minutes of real focus
        XCTAssertEqual(engine.remainingSeconds(at: clock.monotonicSeconds), 0, "clamped")
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 1, accuracy: 1e-12)
        XCTAssertEqual(engine.focusedSeconds(at: clock.monotonicSeconds), 2100, accuracy: 1e-9)

        // Still fully operational after expiry — pause works:
        try engine.pause()
        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 35, "focused kept accumulating past expiry")
        XCTAssertEqual(result.pausedDuration, 0)
        XCTAssertEqual(result.pauseCount, 1)
    }

    func testExpiryProgressClampsAtOneNotBeyond() throws {
        let (engine, clock) = startedEngine(duration: 300)

        clock.advance(by: 900)  // 3× over
        XCTAssertEqual(engine.progressFraction(at: clock.monotonicSeconds), 1, accuracy: 1e-12)
        XCTAssertEqual(engine.focusedSeconds(at: clock.monotonicSeconds), 900, accuracy: 1e-9)
    }

    // MARK: - Pause-gap exclusion (suspend/resume-style) + honest v1 sleep

    func testSuspendResumeStyleGapWhilePausedIsExcludedFromFocused() throws {
        var (engine, clock) = startedEngine(duration: 3600)

        clock.advance(by: 600)  // run 10 min
        try engine.pause()
        clock.advance(by: 300)  // 5-minute suspend/resume-style gap, while paused
        try engine.resume()
        clock.advance(by: 900)  // run 15 min

        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 25, "the paused gap is excluded")
        XCTAssertEqual(result.pausedDuration, 5, "and lands in paused time")
        XCTAssertEqual(result.pauseCount, 1)
    }

    func testUnpausedSleepGapCountsAsFocusedTimeV1Behavior() throws {
        // Documented honest v1 behavior: an UNPAUSED system-sleep gap counts
        // as focused time (PRD §9.3 excludes only paused time; the production
        // monotonic source is ContinuousClock, which ticks through sleep).
        var (engine, clock) = startedEngine(duration: 3600)

        clock.advance(by: 600)   // run 10 min
        clock.advance(by: 300)   // 5-minute sleep gap, session NOT paused
        clock.advance(by: 900)   // run 15 min

        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 30, "the unpaused gap is focused time (v1)")
        XCTAssertEqual(result.pausedDuration, 0)
        XCTAssertEqual(result.pauseCount, 0)
    }

    // MARK: - Clock-change safety (monotonic summation vs wall timestamps)

    func testWallClockJumpBackwardDoesNotAffectDurations() throws {
        var (engine, clock) = startedEngine(duration: 3600)
        let startedAt = clock.wallClockNow

        clock.advance(by: 600)  // run 10 min
        clock.jumpWallClock(by: -2700)  // wall clock jumps back 45 min
        clock.advance(by: 900)  // run 15 min (monotonic keeps flowing)

        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 25, "durations come from monotonic summation")
        XCTAssertEqual(result.pausedDuration, 0)
        XCTAssertEqual(result.startedAt, startedAt)
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt),
            -1200,
            accuracy: 1e-9,
            "timestamps honestly reflect the (broken) wall clock")
    }

    func testWallClockJumpForwardDoesNotAffectDurations() throws {
        var (engine, clock) = startedEngine(duration: 3600)

        clock.advance(by: 600)
        clock.jumpWallClock(by: 7200)  // wall clock jumps forward 2 h (NTP fix)
        clock.advance(by: 600)

        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 20, "never wall-clock subtraction")
        XCTAssertEqual(
            result.endedAt.timeIntervalSince(result.startedAt), 8400, accuracy: 1e-9)
    }

    // MARK: - End while paused

    func testEndWhilePausedClosesThePauseSegment() throws {
        var (engine, clock) = startedEngine(duration: 3600)

        clock.advance(by: 600)
        try engine.pause()
        clock.advance(by: 300)

        let result = try engine.end()

        XCTAssertEqual(result.focusedDuration, 10)
        XCTAssertEqual(result.pausedDuration, 5)
        XCTAssertEqual(result.pauseCount, 1)
    }

    // MARK: - Reusability after end

    func testEngineIsReusableAfterEndWithFreshTelemetry() throws {
        var (engine, clock) = startedEngine()
        clock.advance(by: 600)
        let first = try engine.end()

        try engine.start(taskID: taskID)  // new lifecycle allowed
        clock.advance(by: 300)
        let second = try engine.end()

        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(second.focusedDuration, 5, "telemetry starts fresh")
        XCTAssertEqual(second.pausedDuration, 0)
        XCTAssertEqual(second.pauseCount, 0)
        XCTAssertEqual(second.startedAt.timeIntervalSince(first.endedAt), 0, accuracy: 1e-9)
    }

    // MARK: - Equatable results (pinned: result type is Equatable)

    func testResultIsEquatable() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let endedAt = Date(timeIntervalSinceReferenceDate: 2500)
        let sessionID = UUID()
        let base = FocusSessionResult(
            sessionID: sessionID, taskID: taskID, startedAt: startedAt, endedAt: endedAt,
            focusedDuration: 25, pauseCount: 1, pausedDuration: 5)

        let same = FocusSessionResult(
            sessionID: sessionID, taskID: taskID, startedAt: startedAt, endedAt: endedAt,
            focusedDuration: 25, pauseCount: 1, pausedDuration: 5)
        XCTAssertEqual(base, same)

        let differentPauseCount = FocusSessionResult(
            sessionID: sessionID, taskID: taskID, startedAt: startedAt, endedAt: endedAt,
            focusedDuration: 25, pauseCount: 2, pausedDuration: 5)
        XCTAssertNotEqual(base, differentPauseCount)
    }
}
