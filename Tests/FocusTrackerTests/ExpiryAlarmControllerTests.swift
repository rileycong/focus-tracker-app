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

    private final class BeepCounter {
        var count = 0
    }

    private final class PlayerSpy: ExpiryAlarmPlaying {
        var playCount = 0
        var stopCount = 0
        var shouldFail = false

        func play() throws {
            playCount += 1
            if shouldFail { throw ExpiryAlarmPlayerError.playbackFailed }
        }

        func stop() { stopCount += 1 }
    }

    /// Records `onStateChange` deliveries in order.
    private final class StateLog {
        private(set) var values: [Bool] = []
        func record(_ value: Bool) { values.append(value) }
    }

    // MARK: - Fixture access

    private var beeps: BeepCounter!
    private var player: PlayerSpy!
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
        let player = PlayerSpy()
        let log = StateLog()
        beeps = counter
        self.player = player
        stateLog = log
        focusBackCount = 0
        let alarm = ExpiryAlarmController(
            player: player,
            fallbackBeep: { counter.count += 1 },
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
        XCTAssertEqual(player.playCount, 0)

        alarm.start()

        XCTAssertTrue(alarm.isAlarming, "start → alarming")
        XCTAssertEqual(player.playCount, 1, "the first media beep is immediate")
        XCTAssertEqual(beeps.count, 0, "successful media playback needs no fallback")
        XCTAssertEqual(stateLog.values, [true], "shake flag on")
    }

    func testStartIsIdempotentWhileAlarming() {
        let alarm = makeController()
        alarm.start()
        alarm.start()
        alarm.start()

        XCTAssertTrue(alarm.isAlarming)
        XCTAssertEqual(player.playCount, 1, "no beep restarts on repeated starts")
        XCTAssertEqual(stateLog.values, [true], "no repeated state flips")
    }

    // MARK: - Stop

    func testStopDeactivatesAndSilencesFocusBack() {
        let alarm = makeController()
        alarm.start()
        alarm.stop()

        XCTAssertFalse(alarm.isAlarming, "stop → not alarming")
        XCTAssertEqual(stateLog.values, [true, false], "shake flag off")
        XCTAssertEqual(player.playCount, 1, "stop invalidates the beep timer")
        XCTAssertEqual(player.stopCount, 1, "stop silences the retained player")
        // The observer is removed on stop: a later activation is ignored.
        postDidBecomeActive()
        XCTAssertEqual(focusBackCount, 0, "no focus-back after stop")
        XCTAssertEqual(player.playCount, 1, "no beep from the ignored activation")
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
        player.playCount = 0  // isolate the post-start window

        postDidBecomeActive()

        XCTAssertFalse(alarm.isAlarming, "focus-back stops the alarm")
        XCTAssertEqual(stateLog.values, [true, false], "shake flag off")
        XCTAssertEqual(focusBackCount, 1, "exactly one focus-back delivery")
        XCTAssertEqual(player.playCount, 0, "no further beeps after focus-back")

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

    func testPlaybackFailureFallsBackOnEveryCadencePulse() {
        let alarm = makeController()
        player.shouldFail = true

        alarm.start()
        alarm.playAlarmPulse()

        XCTAssertEqual(player.playCount, 2, "immediate + one deterministic repeat")
        XCTAssertEqual(beeps.count, 2, "every failed media play uses system fallback")
    }

    func testSuccessfulCadenceRepeatReusesPlayerWithoutFallback() {
        let alarm = makeController()
        alarm.start()

        alarm.playAlarmPulse()
        alarm.playAlarmPulse()

        XCTAssertEqual(player.playCount, 3, "immediate + two repeats")
        XCTAssertEqual(beeps.count, 0)
    }
}
