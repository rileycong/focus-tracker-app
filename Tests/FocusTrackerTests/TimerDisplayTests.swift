import XCTest
@testable import FocusTracker

/// Tests for the #20 pure display helpers (`TimerDisplay`,
/// `TimerDisplayState`) — no SwiftUI, no I/O, no real clock: the countdown
/// formatting boundaries, ETA formatting, session-number computation, trim
/// clamping, and the display-state derivation driven through the engine's
/// pure functions with an injected fake clock (issue #20 criterion 8).
final class TimerDisplayTests: XCTestCase {

    // MARK: - Countdown formatting (PRD §10.1: m:ss below 1 h, h:mm:ss at ≥ 1 h)

    func testCountdownAtZeroShows000() {
        XCTAssertEqual(TimerDisplay.countdownText(remainingSeconds: 0), "0:00")
    }

    func testCountdownClampsNegativeToZero() {
        XCTAssertEqual(TimerDisplay.countdownText(remainingSeconds: -5), "0:00")
    }

    func testCountdownBelowAnHourIsMinutesSeconds() {
        XCTAssertEqual(TimerDisplay.countdownText(remainingSeconds: 25 * 60), "25:00")
        XCTAssertEqual(TimerDisplay.countdownText(remainingSeconds: 4 * 60 + 5), "4:05")
        XCTAssertEqual(TimerDisplay.countdownText(remainingSeconds: 59 * 60 + 59), "59:59")
    }

    func testCountdownExactlyOneHourIsHourMinuteSecond() {
        XCTAssertEqual(TimerDisplay.countdownText(remainingSeconds: 3600), "1:00:00")
    }

    func testCountdownAboveAnHourIncludesHours() {
        XCTAssertEqual(TimerDisplay.countdownText(remainingSeconds: 3601), "1:00:01")
        XCTAssertEqual(
            TimerDisplay.countdownText(remainingSeconds: 2 * 3600 + 2 * 60 + 5),
            "2:02:05")
    }

    // MARK: - ETA formatting (PRD §10.1: wall-clock now + remaining, HH:mm)

    /// Constructs a date at a local wall-clock time so the (local-timezone)
    /// HH:mm rendering is deterministic on any machine.
    private func localDate(hour: Int, minute: Int, second: Int = 0) -> Date {
        Calendar.current.date(
            from: DateComponents(hour: hour, minute: minute, second: second))!
    }

    func testEtaIsWallClockNowPlusRemainingFormattedHHmm() {
        let now = localDate(hour: 10, minute: 15, second: 30)
        // +17 min → 10:32:30, seconds dropped by the HH:mm format.
        XCTAssertEqual(TimerDisplay.etaText(remainingSeconds: 17 * 60, now: now), "10:32")
        // +45 s carries into the next minute.
        XCTAssertEqual(TimerDisplay.etaText(remainingSeconds: 45, now: now), "10:16")
    }

    func testEtaCrossingMidnightWrapsToNextDay() {
        let now = localDate(hour: 23, minute: 59)
        XCTAssertEqual(TimerDisplay.etaText(remainingSeconds: 120, now: now), "00:01")
    }

    func testEtaAtZeroRemainingIsNowItself() {
        let now = localDate(hour: 14, minute: 3)
        XCTAssertEqual(TimerDisplay.etaText(remainingSeconds: 0, now: now), "14:03")
    }

    // MARK: - Session number (PRD §10.1 "Session N today": count + 1)

    private func loggedSession() -> FocusSessionLog {
        FocusSessionLog(
            taskID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            endedAt: Date(timeIntervalSinceReferenceDate: 60),
            focusedDuration: 1, pauseCount: 0, pausedDuration: 0,
            focusRating: 3, energyRating: 3, taskCompleted: false)
    }

    func testSessionNumberFromEmptyListIsOne() {
        XCTAssertEqual(TimerDisplay.sessionNumber(fromSessions: []), 1)
    }

    func testSessionNumberIsCountPlusOne() {
        XCTAssertEqual(TimerDisplay.sessionNumber(fromSessions: [loggedSession()]), 2)
        XCTAssertEqual(
            TimerDisplay.sessionNumber(fromSessions: [loggedSession(), loggedSession()]),
            3)
    }

    // MARK: - Progress → ring trim clamping (0…1, 1 == expired)

    func testRingTrimClampsToUnitInterval() {
        XCTAssertEqual(TimerDisplay.ringTrim(progressFraction: -0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(TimerDisplay.ringTrim(progressFraction: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(TimerDisplay.ringTrim(progressFraction: 0.4), 0.4, accuracy: 1e-12)
        XCTAssertEqual(TimerDisplay.ringTrim(progressFraction: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(TimerDisplay.ringTrim(progressFraction: 1.5), 1, accuracy: 1e-12)
    }

    // MARK: - Display-state derivation through the engine's pure functions
    // (issue #20 criterion 8: coordinator/engine snapshot → display state)

    /// Test clock: monotonic and wall-clock readings are independent knobs
    /// (the same seam the #12 engine tests use).
    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(by seconds: TimeInterval) {
            monotonicSeconds += seconds
            wallClockNow = wallClockNow.addingTimeInterval(seconds)
        }
    }

    /// Derives the display state exactly the way the view does: engine pure
    /// functions at the current monotonic reading + the pause flag.
    private func derive(
        _ engine: FocusSessionEngine, _ clock: FakeClock, paused: Bool
    ) -> TimerDisplayState {
        TimerDisplayState.derive(
            remainingSeconds: engine.remainingSeconds(at: clock.monotonicSeconds),
            progressFraction: engine.progressFraction(at: clock.monotonicSeconds),
            isPaused: paused)
    }

    func testDerivationAtStartShowsFullCountdownAndEmptyRing() throws {
        let clock = FakeClock()
        var engine = FocusSessionEngine(clock: clock)
        try engine.start(taskID: UUID(), duration: 25 * 60)

        let state = derive(engine, clock, paused: false)

        XCTAssertEqual(state.remainingSeconds, 1500)
        XCTAssertEqual(state.countdownText, "25:00")
        XCTAssertEqual(state.ringTrim, 0, accuracy: 1e-12)
        XCTAssertFalse(state.isExpired)
        XCTAssertFalse(state.isPaused)
    }

    func testDerivationMidSessionShrinksRingAndCountsDown() throws {
        let clock = FakeClock()
        var engine = FocusSessionEngine(clock: clock)
        try engine.start(taskID: UUID(), duration: 25 * 60)
        clock.advance(by: 60)

        let state = derive(engine, clock, paused: false)

        XCTAssertEqual(state.remainingSeconds, 1440)
        XCTAssertEqual(state.countdownText, "24:00")
        XCTAssertEqual(state.ringTrim, 60.0 / 1500.0, accuracy: 1e-12)
        XCTAssertFalse(state.isExpired)
    }

    func testPausedDerivationFreezesCountdownAndRing() throws {
        let clock = FakeClock()
        var engine = FocusSessionEngine(clock: clock)
        try engine.start(taskID: UUID(), duration: 25 * 60)
        clock.advance(by: 60)
        try engine.pause()
        // Time passes while paused — the open pause segment contributes
        // nothing to focused time (#12 semantics), so the display freezes.
        clock.advance(by: 30)

        let state = derive(engine, clock, paused: true)

        XCTAssertEqual(state.remainingSeconds, 1440, "paused time does not tick the countdown")
        XCTAssertEqual(state.countdownText, "24:00")
        XCTAssertEqual(state.ringTrim, 60.0 / 1500.0, accuracy: 1e-12, "paused time does not shrink the ring")
        XCTAssertTrue(state.isPaused)
        XCTAssertFalse(state.isExpired)
    }

    func testExpiredDerivationClampsToZeroAndCompleteRing() throws {
        let clock = FakeClock()
        var engine = FocusSessionEngine(clock: clock)
        try engine.start(taskID: UUID(), duration: 60)
        clock.advance(by: 61)

        let state = derive(engine, clock, paused: false)

        XCTAssertEqual(state.remainingSeconds, 0, "engine clamps remaining at 0 (no auto-end)")
        XCTAssertEqual(state.countdownText, "0:00")
        XCTAssertEqual(state.ringTrim, 1, accuracy: 1e-12)
        XCTAssertTrue(state.isExpired)
    }

    func testIdleRemainingNilDerivesToZeroAndExpired() {
        // Documented totality: nil (idle) derives to 0/expired — the timer
        // view only renders while a session is active, but the derivation
        // must remain total.
        let state = TimerDisplayState.derive(
            remainingSeconds: nil, progressFraction: 0, isPaused: false)

        XCTAssertEqual(state.remainingSeconds, 0)
        XCTAssertEqual(state.countdownText, "0:00")
        XCTAssertEqual(state.ringTrim, 0, accuracy: 1e-12)
        XCTAssertTrue(state.isExpired)
        XCTAssertFalse(state.isPaused)
    }
}
