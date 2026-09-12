import XCTest
@testable import FocusTracker

/// Tests for the #13 `ActiveSessionSnapshot` and its capture path: the
/// pinned checkpoint math (open run/pause segment folded into its
/// accumulator by pure arithmetic) and the pinned snake_case JSON shape.
final class ActiveSessionSnapshotTests: XCTestCase {

    // MARK: - Fixtures and helpers

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(by seconds: TimeInterval) {
            monotonicSeconds += seconds
            wallClockNow = wallClockNow.addingTimeInterval(seconds)
        }
    }

    private let taskID = UUID()

    private func makeEngine(duration: TimeInterval = 3600)
        -> (engine: FocusSessionEngine, clock: FakeClock) {
        let clock = FakeClock()
        var engine = FocusSessionEngine(clock: clock)
        try? engine.start(taskID: taskID, duration: duration)
        return (engine, clock)
    }

    // MARK: - Capture: checkpoint math (pinned, criterion 1)

    func testCaptureWhileRunningCheckpointsOpenRunSegmentIntoAccumulator() throws {
        var (engine, clock) = makeEngine()
        clock.advance(by: 240)  // open run segment: 240 s

        let snapshot = try XCTUnwrap(engine.captureSnapshot())

        XCTAssertEqual(snapshot.accumulatedFocusedSeconds, 240, accuracy: 1e-9)
        XCTAssertEqual(snapshot.accumulatedPausedSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.pauseCount, 0)
        XCTAssertEqual(snapshot.isPaused, false)
        // Anchor = the save-instant reading (the checkpointed segment's
        // successor opens there — pinned restoration math).
        XCTAssertEqual(snapshot.segmentStartMonotonic, 240, accuracy: 1e-9)
        XCTAssertEqual(snapshot.taskID, taskID)
        XCTAssertEqual(snapshot.duration, 3600, accuracy: 1e-9)
        XCTAssertEqual(snapshot.startedAt, FakeClock().wallClockNow)
    }

    func testCaptureWhilePausedCheckpointsOpenPauseSegmentIntoAccumulator() throws {
        var (engine, clock) = makeEngine()
        clock.advance(by: 600)
        try engine.pause()
        clock.advance(by: 90)  // open pause segment: 90 s

        let snapshot = try XCTUnwrap(engine.captureSnapshot())

        XCTAssertEqual(snapshot.accumulatedFocusedSeconds, 600, accuracy: 1e-9)
        XCTAssertEqual(snapshot.accumulatedPausedSeconds, 90, accuracy: 1e-9)
        XCTAssertEqual(snapshot.pauseCount, 1)
        XCTAssertEqual(snapshot.isPaused, true)
        XCTAssertEqual(snapshot.segmentStartMonotonic, 690, accuracy: 1e-9)
    }

    func testCaptureIsAPureReadAndDoesNotMutateLiveState() throws {
        // captureSnapshot is a non-mutating `func` on the engine struct, so
        // the compiler itself forbids live-state mutation; these assertions
        // pin the observable semantics (criterion 1: "no live mutation").
        var (engine, clock) = makeEngine()
        clock.advance(by: 240)

        let first = try XCTUnwrap(engine.captureSnapshot())
        let second = try XCTUnwrap(engine.captureSnapshot())
        XCTAssertEqual(first, second, "repeated captures at one instant are identical")

        // The live segment was neither closed nor re-anchored by capture.
        clock.advance(by: 60)
        XCTAssertEqual(engine.focusedSeconds(at: clock.monotonicSeconds), 300, accuracy: 1e-9)

        // Lifecycle telemetry is untouched by capture.
        try engine.pause()
        XCTAssertEqual(engine.focusedSeconds(at: clock.monotonicSeconds), 300, accuracy: 1e-9)
        try engine.resume()
        clock.advance(by: 300)
        let result = try engine.end()
        XCTAssertEqual(result.focusedDuration, 10)
        XCTAssertEqual(result.pausedDuration, 0)
        XCTAssertEqual(result.pauseCount, 1)
    }

    func testCaptureWhenIdleReturnsNil() {
        let clock = FakeClock()
        let engine = FocusSessionEngine(clock: clock)
        XCTAssertNil(engine.captureSnapshot())
    }

    // MARK: - Codable round trip

    func testJSONRoundTripPreservesAllFields() throws {
        let snapshot = ActiveSessionSnapshot(
            sessionID: UUID(),
            taskID: UUID(),
            duration: 1500,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 600.5,
            accumulatedPausedSeconds: 90.25,
            pauseCount: 1,
            isPaused: true,
            segmentStartMonotonic: 690.75)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ActiveSessionSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot, "round-trip equality (criterion 7)")
    }

    func testJSONUsesPinnedSnakeCaseKeys() throws {
        let sessionID = UUID()
        let taskID = UUID()
        let snapshot = ActiveSessionSnapshot(
            sessionID: sessionID,
            taskID: taskID,
            duration: 1500,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 600,
            accumulatedPausedSeconds: 90,
            pauseCount: 1,
            isPaused: true,
            segmentStartMonotonic: 690)

        let data = try JSONEncoder().encode(snapshot)
        let json = String(decoding: data, as: UTF8.self)
        for key in [
            "session_id", "task_id", "duration", "started_at",
            "accumulated_focused_seconds", "accumulated_paused_seconds",
            "pause_count", "is_paused", "segment_start_monotonic",
        ] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing pinned key \(key)")
        }

        // Decode hand-written JSON using exactly the pinned key names.
        let handwritten = """
        {
          "session_id": "\(sessionID.uuidString)",
          "task_id": "\(taskID.uuidString)",
          "duration": 1500,
          "started_at": 800000000.0,
          "accumulated_focused_seconds": 600,
          "accumulated_paused_seconds": 90,
          "pause_count": 1,
          "is_paused": true,
          "segment_start_monotonic": 690
        }
        """
        let decoded = try JSONDecoder().decode(
            ActiveSessionSnapshot.self, from: Data(handwritten.utf8))
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.taskID, taskID)
        XCTAssertEqual(decoded.duration, 1500, accuracy: 1e-9)
        XCTAssertEqual(decoded.startedAt, Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(decoded.accumulatedFocusedSeconds, 600, accuracy: 1e-9)
        XCTAssertEqual(decoded.accumulatedPausedSeconds, 90, accuracy: 1e-9)
        XCTAssertEqual(decoded.pauseCount, 1)
        XCTAssertEqual(decoded.isPaused, true)
        XCTAssertEqual(decoded.segmentStartMonotonic, 690, accuracy: 1e-9)
    }
}
