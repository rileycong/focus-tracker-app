import XCTest
@testable import FocusTracker

/// Tests for the #13 engine extension: `restore(from:)` continuity in a new
/// process epoch, driven by fake clocks whose monotonic and wall-clock
/// readings advance independently. The pinned criterion: restoration
/// produces **identical timing results** to the uninterrupted original run.
final class FocusSessionEngineRestoreTests: XCTestCase {

    // MARK: - Fixtures and helpers

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(by seconds: TimeInterval) {
            monotonicSeconds += seconds
            wallClockNow = wallClockNow.addingTimeInterval(seconds)
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FocusSessionEngineRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makeEngine(duration: TimeInterval)
        -> (engine: FocusSessionEngine, clock: FakeClock) {
        let clock = FakeClock()
        var engine = FocusSessionEngine(clock: clock)
        try? engine.start(taskID: taskID, duration: duration)
        return (engine, clock)
    }

    private let taskID = UUID()

    // MARK: - Pinned continuity (criterion 7)

    func testPinnedContinuityRun10PauseSaveRestoreResumeRun15Focused25() throws {
        // Original: run 10 min → pause → save (via the full file pipeline).
        var (original, originalClock) = makeEngine(duration: 3600)
        originalClock.advance(by: 600)
        try original.pause()
        let snapshot = try XCTUnwrap(original.captureSnapshot())

        let persistence = FileActiveSessionPersistence(
            directory: root.appendingPathComponent("snapshot", isDirectory: true))
        try persistence.save(snapshot)
        let reloaded = try XCTUnwrap(try persistence.load())

        // New "process": brand-new engine, brand-new clock epoch.
        let newClock = FakeClock()
        var restored = FocusSessionEngine(clock: newClock)
        try restored.restore(from: reloaded)
        try restored.resume()
        newClock.advance(by: 900)  // run 15 min in the new epoch

        let result = try restored.end()

        XCTAssertEqual(result.focusedDuration, 25)
        XCTAssertEqual(result.pausedDuration, 0)
        XCTAssertEqual(result.pauseCount, 1)
        XCTAssertEqual(result.sessionID, snapshot.sessionID, "session_id carried verbatim")
        XCTAssertEqual(result.startedAt, snapshot.startedAt, "started_at carried verbatim")
        XCTAssertEqual(result.taskID, taskID)
    }

    func testRestoredRunMatchesUninterruptedOriginalResultExactly() throws {
        // Path A (original, uninterrupted): run 10, pause 5, resume, run 15.
        // Path B: run 10, pause, (5 min of pause pass), SAVE at that exact
        // instant, restore into a new engine + fresh epoch, resume, run 15.
        // Both must end with identical FocusSessionResults.
        var (original, originalClock) = makeEngine(duration: 3600)
        originalClock.advance(by: 600)
        try original.pause()
        originalClock.advance(by: 300)
        let snapshot = try XCTUnwrap(original.captureSnapshot())

        let newClock = FakeClock()
        newClock.wallClockNow = originalClock.wallClockNow  // aligned epochs
        var restored = FocusSessionEngine(clock: newClock)
        try restored.restore(from: snapshot)
        try restored.resume()

        // Both continue in lockstep from the save/restore instant: the
        // original closes its 5-min pause segment and runs on; the restored
        // engine already carried the checkpointed pause segment.
        try original.resume()
        originalClock.advance(by: 900)
        newClock.advance(by: 900)

        let originalResult = try original.end()
        let restoredResult = try restored.end()

        XCTAssertEqual(restoredResult, originalResult,
                       "restoration produces identical timing results")
        XCTAssertEqual(originalResult.focusedDuration, 25)
        XCTAssertEqual(originalResult.pausedDuration, 5)
        XCTAssertEqual(originalResult.pauseCount, 1)
    }

    func testRestoreContinuityWhileRunningCheckpointsOpenRunSegment() throws {
        // Save while RUNNING (no pause): the open run segment (600 s) must be
        // checkpointed into the focused accumulator at capture.
        var (original, originalClock) = makeEngine(duration: 3600)
        originalClock.advance(by: 600)

        let snapshot = try XCTUnwrap(original.captureSnapshot())
        XCTAssertEqual(snapshot.accumulatedFocusedSeconds, 600, accuracy: 1e-9)
        XCTAssertEqual(snapshot.isPaused, false)

        let newClock = FakeClock()
        var restored = FocusSessionEngine(clock: newClock)
        try restored.restore(from: snapshot)
        newClock.advance(by: 900)  // run 15 more, no pause/resume involved

        let result = try restored.end()
        XCTAssertEqual(result.focusedDuration, 25)
        XCTAssertEqual(result.pausedDuration, 0)
        XCTAssertEqual(result.pauseCount, 0)
        XCTAssertEqual(result.sessionID, snapshot.sessionID)
        XCTAssertEqual(result.startedAt, snapshot.startedAt)
    }

    // MARK: - Re-anchoring into the new epoch

    func testRestoreReanchorsIntoNewEpochImmediately() throws {
        // Snapshot carries accF = 600 from the OLD epoch; in the new engine
        // the open segment starts at the new epoch's current reading.
        let snapshot = ActiveSessionSnapshot(
            sessionID: UUID(),
            taskID: taskID,
            duration: 1500,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 600,
            accumulatedPausedSeconds: 0,
            pauseCount: 0,
            isPaused: false,
            segmentStartMonotonic: 987_654)  // old-epoch garbage: never read

        let newClock = FakeClock()
        newClock.advance(by: 123)  // new epoch already at 123 s
        var engine = FocusSessionEngine(clock: newClock)
        try engine.restore(from: snapshot)

        // Right after restore: carried accumulator + max(0, now − new anchor).
        XCTAssertEqual(
            engine.focusedSeconds(at: newClock.monotonicSeconds), 600, accuracy: 1e-9)
        XCTAssertEqual(engine.remainingSeconds(at: newClock.monotonicSeconds), 900)
        newClock.advance(by: 60)
        XCTAssertEqual(
            engine.focusedSeconds(at: newClock.monotonicSeconds), 660, accuracy: 1e-9,
            "summation continues seamlessly from the new epoch's anchor")
    }

    func testRestorePausedPhaseFreezesFocusedAndAccruesPausedUntilResume() throws {
        let snapshot = ActiveSessionSnapshot(
            sessionID: UUID(),
            taskID: taskID,
            duration: 3600,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 600,
            accumulatedPausedSeconds: 300,
            pauseCount: 1,
            isPaused: true,
            segmentStartMonotonic: 900)

        let newClock = FakeClock()
        var engine = FocusSessionEngine(clock: newClock)
        try engine.restore(from: snapshot)

        newClock.advance(by: 120)  // pause continues in the new epoch
        XCTAssertEqual(
            engine.focusedSeconds(at: newClock.monotonicSeconds), 600, accuracy: 1e-9,
            "focused time is frozen while the restored session stays paused")
        XCTAssertEqual(engine.remainingSeconds(at: newClock.monotonicSeconds), 3000)

        try engine.resume()
        newClock.advance(by: 900)
        let result = try engine.end()
        XCTAssertEqual(result.focusedDuration, 25)
        XCTAssertEqual(result.pausedDuration, 7)  // 300 carried + 120 accrued
        XCTAssertEqual(result.pauseCount, 1)
        XCTAssertEqual(result.sessionID, snapshot.sessionID)
    }

    func testRestorePreservesTelemetryAcrossMultiplePauseCycles() throws {
        // run 100, pause 50, resume, run 200, pause 80, resume, run 150,
        // then split: original continues 150 more; a snapshot taken at the
        // split point is restored into a new engine which continues 150 more.
        var (original, originalClock) = makeEngine(duration: 3600)
        originalClock.advance(by: 100)
        try original.pause()
        originalClock.advance(by: 50)
        try original.resume()
        originalClock.advance(by: 200)
        try original.pause()
        originalClock.advance(by: 80)
        try original.resume()
        originalClock.advance(by: 150)
        let snapshot = try XCTUnwrap(original.captureSnapshot())

        let newClock = FakeClock()
        newClock.wallClockNow = originalClock.wallClockNow
        var restored = FocusSessionEngine(clock: newClock)
        try restored.restore(from: snapshot)

        originalClock.advance(by: 150)
        newClock.advance(by: 150)

        XCTAssertEqual(try restored.end(), try original.end())
    }

    // MARK: - Guard rails

    func testRestoreIntoActiveEngineThrowsSessionAlreadyActiveAndLeavesItUntouched() throws {
        var (active, activeClock) = makeEngine(duration: 3600)
        activeClock.advance(by: 600)
        try active.pause()
        let snapshot = try XCTUnwrap(active.captureSnapshot())

        var (other, otherClock) = makeEngine(duration: 600)
        otherClock.advance(by: 60)

        XCTAssertThrowsError(try other.restore(from: snapshot)) { error in
            XCTAssertEqual(error as? FocusSessionError, .sessionAlreadyActive)
        }
        // The live session is untouched by the refused restore (no silent
        // overwrite, PRD §18).
        XCTAssertEqual(other.remainingSeconds(at: otherClock.monotonicSeconds), 540)
        try other.pause()
        let result = try other.end()
        XCTAssertEqual(result.focusedDuration, 1)
        XCTAssertEqual(result.pauseCount, 1)
    }
}
