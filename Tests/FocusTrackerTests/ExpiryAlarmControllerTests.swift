import XCTest
import AppKit
@testable import FocusTracker

/// Tests for the #33 `ExpiryAlarmController` state machine (issue #33): the
/// alarm state transitions (start → alarming with an immediate beep;
/// idempotent start; stop → silenced, timer invalidated, observer removed),
/// the focus-back watch (didBecomeActive while alarming → stop + exactly
/// one focus-back delivery; ignored when not alarming), and the callback
/// surface that drives `AppModel.isExpiryAlarmActive`. AppKit is never
/// touched: the beep is a counting closure and the focus-back signal is
/// posted by the tests themselves (selector-based observers deliver
/// synchronously on the posting thread — deterministic, no run-loop spins).
@MainActor
final class ExpiryAlarmControllerTests: XCTestCase {

    // MARK: - Test doubles

    /// The injected beep action's counter (no real `NSBeep` in tests).
    private final class BeepCounter {
        var count = 0
    }

    /// Records `onStateChange` deliveries in order.
    private final class StateLog {
        private(set) var values: [Bool] = []
        func record(_ value: Bool) { values.append(value) }
    }

    // MARK: - Fixture access

    private var beeps: BeepCounter!
    private var stateLog: StateLog!
    private var focusBackCount = 0
    private var controller: ExpiryAlarmController!

    override func tearDownWithError() throws {
        // No armed alarm may outlive a test (the deinit safety net would
        // catch it, but an explicit stop keeps the run loop clean).
        controller?.stop()
        controller = nil
        try super.tearDownWithError()
    }

    private func makeController() -> ExpiryAlarmController {
        let counter = BeepCounter()
        let log = StateLog()
        beeps = counter
        stateLog = log
        focusBackCount = 0
        let alarm = ExpiryAlarmController(
            beep: { counter.count += 1 },
            isAppActive: { false })
        alarm.onStateChange = { log.record($0) }
        alarm.onFocusBack = { [weak self] in self?.focusBackCount += 1 }
        controller = alarm
        return alarm
    }

    private func postDidBecomeActive() {
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - Start

    func testStartActivatesAlarmAndBeepsImmediately() {
        let alarm = makeController()
        XCTAssertFalse(alarm.isAlarming)
        XCTAssertEqual(beeps.count, 0)

        alarm.start()

        XCTAssertTrue(alarm.isAlarming, "start → alarming")
        XCTAssertEqual(beeps.count, 1, "the first beep is immediate")
        XCTAssertEqual(stateLog.values, [true], "shake flag on")
    }

    func testStartIsIdempotentWhileAlarming() {
        let alarm = makeController()
        alarm.start()
        alarm.start()
        alarm.start()

        XCTAssertTrue(alarm.isAlarming)
        XCTAssertEqual(beeps.count, 1, "no beep restarts on repeated starts")
        XCTAssertEqual(stateLog.values, [true], "no repeated state flips")
    }

    // MARK: - Stop

    func testStopDeactivatesAndSilencesFocusBack() {
        let alarm = makeController()
        alarm.start()
        alarm.stop()

        XCTAssertFalse(alarm.isAlarming, "stop → not alarming")
        XCTAssertEqual(stateLog.values, [true, false], "shake flag off")
        XCTAssertEqual(beeps.count, 1, "stop invalidates the beep timer")
        // The observer is removed on stop: a later activation is ignored.
        postDidBecomeActive()
        XCTAssertEqual(focusBackCount, 0, "no focus-back after stop")
        XCTAssertEqual(beeps.count, 1, "no beep from the ignored activation")
    }

    func testStopIsIdempotentWhenNotAlarming() {
        let alarm = makeController()
        alarm.stop()
        alarm.start()
        alarm.stop()
        alarm.stop()

        XCTAssertFalse(alarm.isAlarming)
        XCTAssertEqual(stateLog.values, [true, false], "exactly one flip pair")
    }

    // MARK: - Focus back

    func testFocusBackWhileAlarmingStopsAndDeliversFocusBackOnce() {
        let alarm = makeController()
        alarm.start()
        beeps.count = 0  // isolate the post-start window

        postDidBecomeActive()

        XCTAssertFalse(alarm.isAlarming, "focus-back stops the alarm")
        XCTAssertEqual(stateLog.values, [true, false], "shake flag off")
        XCTAssertEqual(focusBackCount, 1, "exactly one focus-back delivery")
        XCTAssertEqual(beeps.count, 0, "no further beeps after focus-back")

        // A second activation (no new alarm) delivers nothing.
        postDidBecomeActive()
        XCTAssertEqual(focusBackCount, 1)
    }

    func testFocusBackIgnoredWhenNotAlarming() {
        let alarm = makeController()
        postDidBecomeActive()

        XCTAssertFalse(alarm.isAlarming)
        XCTAssertEqual(focusBackCount, 0, "no alarm → no focus-back signal")
        XCTAssertEqual(stateLog.values, [])
    }
}
