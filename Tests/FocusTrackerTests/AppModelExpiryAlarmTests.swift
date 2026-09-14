import XCTest
import AppKit
@testable import FocusTracker

/// Tests for the #33 expiry alarm + focus-back auto-end on `AppModel`
/// (issue #33): the watcher state machine (expiry-while-unfocused → alarm
/// with an immediate beep and an exactly-once latch; expiry-while-active →
/// straight auto-end, no alarm; focus-back → alarm stop + auto-end + the
/// #22 modal WITHOUT the End/Cancel confirm), the expiry-instant log
/// composition (ended_at == started_at + duration, #27-invariant-safe
/// minutes, parse-back through a fresh `DailyLogStore`), the #29
/// cancel-resume of the auto-end modal (restored AT the expiry instant and
/// latched — no instant re-end; further time counts as focused), the
/// defensive manual-end stop (manual semantics keep their wall-clock
/// ended_at), the #13 recovery interplay (a restored expired snapshot is
/// handled, not re-ended), the watcher re-arm on a fresh session, and the
/// mini-mode restore on alarm start. Temp-dir fixture copy per the
/// established pattern; `NSBeep` and app activation are injected closures
/// (the beep counted, activation a mutable probe), and the focus-back
/// signal is delivered by posting the activation notification exactly as
/// AppKit does.
@MainActor
final class AppModelExpiryAlarmTests: XCTestCase {

    // MARK: - Test doubles (same seams as the #13/#14/#19/#22 tests)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        /// Advances both readings together (monotonic drives the durations,
        /// wall clock the §13 timestamps).
        func advance(by interval: TimeInterval) {
            monotonicSeconds += interval
            wallClockNow = wallClockNow.addingTimeInterval(interval)
        }
    }

    private final class ManualTickScheduler: ActiveSessionTickScheduler,
        @unchecked Sendable {
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
    }

    /// The injected app-active probe — the model's "expiry while focused
    /// vs unfocused" decision input.
    private final class FocusProbe {
        var isActive = false
    }

    /// The injected beep action's counter (no real `NSBeep` in tests).
    private final class BeepCounter {
        var count = 0
    }

    private struct TestFailure: Error {}

    // MARK: - Fixture access

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private var root: URL!
    private var vaultURL: URL!
    private var persistenceDirectory: URL!
    private var suiteName: String!
    private var settings: AppSettings!
    private var clock: FakeClock!
    private var focusProbe: FocusProbe!
    private var beeps: BeepCounter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "ExpiryAlarmTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "ExpiryAlarmTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
        clock = FakeClock()
        focusProbe = FocusProbe()
        beeps = BeepCounter()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let probe = focusProbe!
        let counter = beeps!
        let alarm = ExpiryAlarmController(
            beep: { counter.count += 1 },
            isAppActive: { probe.isActive })
        let model = AppModel(
            settings: settings, persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(), sessionClock: clock,
            expiryAlarm: alarm)
        await model.bootstrap()
        return model
    }

    private func writeTaskFile(
        _ title: String, id: UUID, status: TaskStatus = .toDo, in vault: URL
    ) throws {
        let lines = [
            "---",
            "id: \(id.uuidString)",
            "title: \(title)",
            "status: \(status.rawValue)",
            "categories:",
            "  - Testing",
            "---",
        ]
        try lines.joined(separator: "\n").write(
            to: vault.appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent("\(title).md"),
            atomically: true, encoding: .utf8)
    }

    private func startRunningSession(
        on model: AppModel, taskID: UUID, duration: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> AppModel.SessionContext {
        let outcome = try await model.startSession(taskID: taskID, duration: duration)
        guard case .started(let context) = outcome else {
            XCTFail("expected .started(...), got \(outcome)", file: file, line: line)
            throw TestFailure()
        }
        return context
    }

    /// A 60-second session with a pre-expiry pause: 20 s focus → 24 s pause
    /// → 40 s focus reaches expiry (focused exactly 60 s = the duration) at
    /// wall +84, carrying 24 paused seconds and pause count 1. The 24 s
    /// pause rounds to 0 whole minutes (24/60 → 0 under the pinned
    /// nearest-minute rule), keeping the #27 minute invariant crisp for the
    /// log/cancel assertions below.
    private func runPausedSessionToExpiry(
        on model: AppModel, taskID: UUID,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> AppModel.SessionContext {
        let context = try await startRunningSession(
            on: model, taskID: taskID, duration: 60, file: file, line: line)
        clock.advance(by: 20)
        try model.pauseSession()
        clock.advance(by: 24)
        try model.resumeSession()
        clock.advance(by: 40)
        return context
    }

    private func makeForm(
        completed: EndOfSessionFormState.CompletedChoice = .no,
        focus: Int = 4, energy: Int = 3, notes: String = ""
    ) -> EndOfSessionFormState {
        var form = EndOfSessionFormState()
        form.completedChoice = completed
        form.focusRating = focus
        form.energyRating = energy
        form.notes = notes
        return form
    }

    /// Delivers the focus-back signal exactly as AppKit does: posting the
    /// activation notification on the main thread (the controller's
    /// selector-based observer handles it synchronously).
    private func focusBack() {
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// The logged session parsed back from the END-day file on disk (a
    /// fresh store — the parse-back the issue pins).
    private func parseBackSession(
        _ result: FocusSessionResult, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> FocusSessionLog {
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(
            for: AppModel.logDay(forEndedAt: result.endedAt))
        return try XCTUnwrap(
            day.sessions.first { $0.sessionID == result.sessionID },
            "session present in the end-day file", file: file, line: line)
    }

    private func assertEndingPhase(
        _ phase: AppModel.AppPhase, context: AppModel.SessionContext,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (result: FocusSessionResult, snapshot: ActiveSessionSnapshot) {
        guard case .endingSession(let result, let snapshot, let endingContext) = phase else {
            XCTFail("expected .endingSession(...), got \(phase)", file: file, line: line)
            throw TestFailure()
        }
        XCTAssertEqual(endingContext, context, "ending context", file: file, line: line)
        return (result, snapshot)
    }

    // MARK: - Expiry while unfocused → alarm

    func testExpiryWhileUnfocusedStartsAlarmAndBeepsImmediately() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(
            on: model, taskID: taskID, duration: 60)

        clock.advance(by: 60)
        model.evaluateSessionExpiry()

        XCTAssertTrue(model.isExpiryAlarmActive, "expired + unfocused → alarm")
        XCTAssertEqual(beeps.count, 1, "the alarm's first beep is immediate")
        XCTAssertEqual(model.appPhase, .timerView(context), "no modal yet")
        XCTAssertEqual(model.sessionState, .running, "not auto-ended yet")
    }

    func testRepeatedTicksWhileAlarmingDoNotRestartAlarm() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(
            on: model, taskID: taskID, duration: 60)

        clock.advance(by: 60)
        model.evaluateSessionExpiry()
        model.evaluateSessionExpiry()
        model.evaluateSessionExpiry()

        XCTAssertTrue(model.isExpiryAlarmActive, "the alarm keeps running")
        XCTAssertEqual(
            beeps.count, 1,
            "the exactly-once latch: repeated ticks restart nothing (bounded alarm loop)")
        XCTAssertEqual(model.appPhase, .timerView(context))
    }

    // MARK: - Focus back → stop + auto-end + modal, no confirm

    func testFocusBackStopsAlarmAndAutoEndsWithoutConfirm() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(
            on: model, taskID: taskID, duration: 60)

        clock.advance(by: 60)
        model.evaluateSessionExpiry()
        beeps.count = 0
        focusProbe.isActive = true
        focusBack()

        XCTAssertFalse(model.isExpiryAlarmActive, "the alarm stops on focus-back")
        XCTAssertEqual(beeps.count, 0, "no beep from the focus-back itself")
        XCTAssertEqual(model.sessionState, .idle, "the session ended at focus-back")
        XCTAssertFalse(model.isSessionActive)
        let (result, snapshot) = try assertEndingPhase(model.appPhase, context: context)
        XCTAssertEqual(
            result.endedAt, result.startedAt.addingTimeInterval(60),
            "ended_at pinned to the expiry instant")
        XCTAssertEqual(
            result.focusedDuration, 1,
            "the configured duration in whole minutes (the honest modal display)")
        XCTAssertEqual(
            snapshot.accumulatedFocusedSeconds, 60, "expiry-instant snapshot")
        // Refusal parity with the manual flow (standard #22): the modal
        // blocks a new session.
        let outcome = try await model.startSession(taskID: taskID)
        XCTAssertEqual(outcome, .refused(.sessionEndingUnresolved))
    }

    // MARK: - Expiry while active → straight auto-end, no alarm

    func testExpiryWhileActiveAutoEndsStraightToModalWithoutAlarm() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(
            on: model, taskID: taskID, duration: 60)
        focusProbe.isActive = true

        clock.advance(by: 60)
        model.evaluateSessionExpiry()

        XCTAssertFalse(model.isExpiryAlarmActive, "no alarm while focused (pinned)")
        XCTAssertEqual(beeps.count, 0, "no beep at all on this path")
        XCTAssertEqual(model.sessionState, .idle)
        let (result, _) = try assertEndingPhase(model.appPhase, context: context)
        XCTAssertEqual(result.endedAt, result.startedAt.addingTimeInterval(60))
    }

    func testTickBeforeExpiryDoesNothing() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(
            on: model, taskID: taskID, duration: 60)

        clock.advance(by: 30)
        model.evaluateSessionExpiry()

        XCTAssertFalse(model.isExpiryAlarmActive)
        XCTAssertEqual(beeps.count, 0)
        XCTAssertEqual(model.appPhase, .timerView(context))
        XCTAssertEqual(model.sessionState, .running)
    }

    // MARK: - Log composition (ended_at = expiry instant, parse-back)

    func testAutoEndLogParsesBackWithExpiryEndedAtAndInvariantSafeMinutes() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runPausedSessionToExpiry(on: model, taskID: taskID)

        model.evaluateSessionExpiry()  // unfocused → alarm
        focusProbe.isActive = true
        focusBack()                    // → auto-end + modal

        guard case .endingSession(let result, _, _) = model.appPhase else {
            XCTFail("expected .endingSession, got \(model.appPhase)")
            throw TestFailure()
        }
        let form = makeForm()
        let outcome = try await model.submitEndOfSession(form)
        XCTAssertEqual(outcome, .success)

        let log = try await parseBackSession(result)
        XCTAssertEqual(log.startedAt, result.startedAt)
        XCTAssertEqual(
            log.endedAt, result.startedAt.addingTimeInterval(60),
            "ended_at == started_at + duration (the expiry instant — no overrun)")
        XCTAssertEqual(log.focusedDuration, 1, "the span is exactly the duration")
        XCTAssertEqual(log.pausedDuration, 0, "the 24 s pause rounds to 0 minutes")
        XCTAssertEqual(log.pauseCount, 1)
        // The #27 invariant, now exact because the span IS the duration.
        XCTAssertEqual(
            log.focusedDuration + log.pausedDuration,
            EndOfSessionFormState.nearestMinute(
                fromSeconds: log.endedAt.timeIntervalSince(log.startedAt)),
            "focused + paused == span (invariant-safe minutes)")
        XCTAssertEqual(log.taskCompleted, false)
    }

    // MARK: - Cancel-resume from the auto-end modal (#29 × #33)

    func testCancelResumeRestoresExpiryStateAndLatchesWatcher() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await runPausedSessionToExpiry(on: model, taskID: taskID)

        model.evaluateSessionExpiry()
        focusBack()

        // The retained snapshot is the EXPIRY-INSTANT state (pinned):
        // focused accumulators == duration, pre-expiry pauses, running.
        let (_, snapshot) = try assertEndingPhase(model.appPhase, context: context)
        XCTAssertEqual(
            snapshot.accumulatedFocusedSeconds, 60,
            "focused pinned to the expiry instant (the engine's overrun amended away)")
        XCTAssertEqual(snapshot.accumulatedPausedSeconds, 24, "pre-expiry pauses kept")
        XCTAssertEqual(snapshot.pauseCount, 1)
        XCTAssertFalse(snapshot.isPaused, "expiry is only reachable while running")
        XCTAssertEqual(snapshot.duration, 60)

        let outcome = try model.cancelEndOfSession()
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertEqual(model.appPhase, .timerView(context))
        XCTAssertEqual(model.focusedSeconds, 60, "restored AT the expiry instant")
        XCTAssertEqual(model.remainingSeconds, 0, "still expired")

        // The watcher is latched for this lifecycle: resuming an expired
        // session counts further time as focused, with NO instant re-alarm
        // or re-end — the next END reconciles again (ordinary #27).
        beeps.count = 0
        clock.advance(by: 30)
        model.evaluateSessionExpiry()
        XCTAssertFalse(model.isExpiryAlarmActive, "no re-alarm after cancel-resume")
        XCTAssertEqual(beeps.count, 0)
        XCTAssertEqual(model.appPhase, .timerView(context), "the session continues")
        XCTAssertEqual(model.focusedSeconds, 90, "further time counts as focused")
    }

    // MARK: - Discard from the auto-end modal (#27)

    func testDiscardFromAutoEndModalWritesNothing() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID, duration: 60)
        focusProbe.isActive = true

        clock.advance(by: 60)
        model.evaluateSessionExpiry()  // expiry-while-active → modal

        model.discardEndOfSession()

        XCTAssertEqual(model.appPhase, .tasksView)
        XCTAssertFalse(model.isSessionActive)
        // Nothing was logged.
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(
            for: AppModel.logDay(forEndedAt: clock.wallClockNow))
        XCTAssertTrue(day.sessions.isEmpty, "discard writes nothing")
    }

    // MARK: - Manual end while alarming (the race; defensive stop)

    func testManualEndWhileAlarmingStopsAlarmAndKeepsManualTimestamps() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID, duration: 60)

        clock.advance(by: 60)
        model.evaluateSessionExpiry()  // unfocused → alarm
        XCTAssertTrue(model.isExpiryAlarmActive)
        clock.advance(by: 30)  // ignored, then a manual End lands first

        let result = try model.endSession()

        XCTAssertFalse(model.isExpiryAlarmActive, "any session end stops the alarm")
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertEqual(
            result.endedAt, clock.wallClockNow,
            "the manual path keeps its wall-clock ended_at (whichever path lands first wins)")
    }

    // MARK: - #13 recovery interplay

    func testRecoveryRestoreOfExpiredSnapshotDoesNotReAlarm() async throws {
        // An expired-but-unended session persisted on disk (#13): focused
        // 75 s of a 60 s session — the engine kept accumulating past expiry
        // per #12; recovery still surfaces it.
        let expired = ActiveSessionSnapshot(
            sessionID: UUID(), taskID: UUID(), duration: 60,
            startedAt: clock.wallClockNow,
            accumulatedFocusedSeconds: 75, accumulatedPausedSeconds: 0,
            pauseCount: 0, isPaused: false, segmentStartMonotonic: 75)
        try FileActiveSessionPersistence(directory: persistenceDirectory)
            .save(expired)

        let model = await makeConfiguredModel()
        XCTAssertNotNil(
            model.pendingSessionRecovery, "expired-but-unended sessions recover as today")
        XCTAssertEqual(try model.restorePendingSession(), .restored)
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertTrue(model.isSessionExpired, "the restored session is already past expiry")

        model.evaluateSessionExpiry()
        XCTAssertFalse(
            model.isExpiryAlarmActive,
            "an explicitly resumed expired session is handled — not instantly re-ended")
        XCTAssertEqual(beeps.count, 0)
        XCTAssertEqual(model.appPhase, .tasksView, "the watcher touches nothing here")
    }

    // MARK: - Watcher re-arm on a fresh session

    func testFreshSessionReArmsWatcherAfterHandledExpiry() async throws {
        // Both task files are written BEFORE the model bootstraps: the
        // vault inventory is a boot-time snapshot (#6/#14).
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let secondID = UUID()
        try writeTaskFile("Deep Work II", id: secondID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID, duration: 60)

        clock.advance(by: 60)
        model.evaluateSessionExpiry()  // unfocused → alarm (beep 1)
        focusBack()                    // → auto-end + modal
        let outcome = try await model.submitEndOfSession(makeForm())
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .tasksView)

        // A fresh session re-arms the watcher: it alarms at ITS expiry.
        _ = try await startRunningSession(on: model, taskID: secondID, duration: 60)
        clock.advance(by: 60)
        model.evaluateSessionExpiry()
        XCTAssertTrue(model.isExpiryAlarmActive, "a fresh session watches again")
        XCTAssertEqual(beeps.count, 2, "one beep per alarm start across both sessions")
    }

    // MARK: - Mini mode

    func testAlarmFromMiniModeRestoresFullTimer() async throws {
        let taskID = UUID()
        try writeTaskFile("Deep Work", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID, duration: 60)
        model.collapseToMiniTimer()
        XCTAssertTrue(model.isMiniTimerActive)

        clock.advance(by: 60)
        model.evaluateSessionExpiry()

        XCTAssertTrue(model.isExpiryAlarmActive, "unfocused expiry → alarm")
        XCTAssertFalse(
            model.isMiniTimerActive,
            "the alarm restores the full timer — the shake is a full-window affordance")
        XCTAssertEqual(beeps.count, 1)
    }
}
