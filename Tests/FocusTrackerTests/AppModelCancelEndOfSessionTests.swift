import XCTest
@testable import FocusTracker

/// Tests for the #29 Cancel on the end-of-session modal: the end-instant
/// snapshot capture into the `.endingSession` phase (BEFORE `coordinator.end()`
/// — after end the engine is idle and capture returns nil), the read-only
/// coordinator `captureSnapshot()` passthrough, the restore path (running-at-
/// end → re-anchored running with modal time counting nothing; paused-at-end →
/// restored paused with the modal time landing in paused), the no-log
/// invariant on cancel, the exactly-once log of the follow-up end+submit, the
/// autosave re-arm (spy scheduler + tick re-persisting the snapshot), the
/// guard behavior (`.sessionEndingUnresolved` while up; already-active after),
/// and the snapshot drop on submit AND on #27's discard. Temp-dir fixture copy
/// per the established pattern.
@MainActor
final class AppModelCancelEndOfSessionTests: XCTestCase {

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

    /// Manual scheduler that RECORDS the armed tick so tests can assert the
    /// re-arm (the autosave-spy seam) and fire ticks themselves — never a
    /// real sleep.
    private final class SpyTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable () -> Void)?
        private var interval: TimeInterval?

        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {
            lock.withLock {
                self.interval = interval
                self.pending = tick
            }
        }

        func cancel() {
            lock.withLock {
                interval = nil
                pending = nil
            }
        }

        var pendingInterval: TimeInterval? { lock.withLock { interval } }

        func firePendingTick() {
            let tick = lock.withLock { pending }
            tick?()
        }
    }

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
    private var scheduler: SpyTickScheduler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CancelEndOfSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "CancelEndOfSessionTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
        clock = FakeClock()
        scheduler = SpyTickScheduler()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private struct TestFailure: Error {}

    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let model = AppModel(
            settings: settings, persistenceDirectory: persistenceDirectory,
            scheduler: scheduler, sessionClock: clock)
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
        on model: AppModel, taskID: UUID, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AppModel.SessionContext {
        let outcome = try await model.startSession(taskID: taskID)
        guard case .started(let context) = outcome else {
            XCTFail("expected .started(...), got \(outcome)", file: file, line: line)
            throw TestFailure()
        }
        return context
    }

    /// The pinned 10/5/15 telemetry: 10 min focus, 5 min pause, 15 min focus
    /// → focused 1500 s, paused 300 s accumulated, pause count 1.
    private func runPinnedTelemetry(on model: AppModel) throws {
        clock.advance(by: 600)
        try model.pauseSession()
        clock.advance(by: 300)
        try model.resumeSession()
        clock.advance(by: 900)
    }

    /// The end-day sessions parsed back from disk (a fresh store — never the
    /// model's in-memory copy).
    private func parseBackSessions(forDayOf endedAt: Date) async throws
        -> [FocusSessionLog]
    {
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(for: AppModel.logDay(forEndedAt: endedAt))
        return day.sessions
    }

    /// The on-disk active-session snapshot (a fresh persistence instance over
    /// the same injected directory).
    private func onDiskSnapshot() throws -> ActiveSessionSnapshot? {
        try FileActiveSessionPersistence(directory: persistenceDirectory).load()
    }

    // MARK: - Coordinator passthrough (issue #29 pinned exposure)

    func testCoordinatorCaptureSnapshotIsReadOnlyPassthrough() throws {
        let coordinator = ActiveSessionCoordinator(
            engine: FocusSessionEngine(clock: clock),
            persistence: FileActiveSessionPersistence(directory: persistenceDirectory),
            scheduler: SpyTickScheduler(), autosaveInterval: 30)

        // Idle → nil (the order-matters condition: after end, capture is nil).
        XCTAssertNil(coordinator.captureSnapshot(), "idle → nil")

        // 10 min focus, 5 min open pause.
        try coordinator.start(taskID: UUID(), duration: 1500)
        clock.advance(by: 600)
        try coordinator.pause()
        clock.advance(by: 300)
        let snapshot = try XCTUnwrap(coordinator.captureSnapshot())
        XCTAssertEqual(snapshot.isPaused, true, "the exact end-instant phase")
        XCTAssertEqual(snapshot.accumulatedFocusedSeconds, 600, accuracy: 1e-9)
        XCTAssertEqual(snapshot.accumulatedPausedSeconds, 300, accuracy: 1e-9)
        XCTAssertEqual(snapshot.pauseCount, 1)
        XCTAssertEqual(snapshot.duration, 1500, accuracy: 1e-9, "configured duration carried")

        // Pure read: a second capture at the same instant is identical, and
        // the live engine's open segments are untouched by capturing.
        XCTAssertEqual(coordinator.captureSnapshot(), snapshot)
        clock.advance(by: 45)
        XCTAssertEqual(
            coordinator.focusedSeconds(at: clock.monotonicSeconds), 600, accuracy: 1e-9,
            "focused unchanged (paused); the capture closed no live segment")
        let after = try XCTUnwrap(coordinator.captureSnapshot())
        XCTAssertEqual(after.accumulatedFocusedSeconds, 600, accuracy: 1e-9)
        XCTAssertEqual(
            after.accumulatedPausedSeconds, 345, accuracy: 1e-9,
            "the live pause segment kept accumulating (capture mutated nothing)")

        // The end result proves the run was never perturbed by the captures,
        // and the snapshot carried the same identity.
        let result = try coordinator.end()
        XCTAssertEqual(result.sessionID, snapshot.sessionID)
        XCTAssertEqual(result.startedAt, snapshot.startedAt)
        XCTAssertEqual(result.focusedDuration, 10, "600 s → 10 min")
        XCTAssertEqual(result.pausedDuration, 6, "345 s → nearest minute")
        XCTAssertNil(coordinator.captureSnapshot(), "idle again after end")
    }

    // MARK: - Confirm-End capture into the phase (issue #29)

    func testManualEndConfirmationPausesFreezesAndRecordsDecisionTelemetry() async throws {
        let taskID = UUID()
        try writeTaskFile("Confirm pause task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        clock.advance(by: 600)

        XCTAssertTrue(model.beginEndSessionConfirmation())
        XCTAssertEqual(model.sessionState, .paused)
        XCTAssertEqual(model.focusedSeconds, 600, accuracy: 1e-9)
        clock.advance(by: 120)
        XCTAssertEqual(model.focusedSeconds, 600, accuracy: 1e-9, "decision time is not focused")

        let result = try model.endSession()
        XCTAssertEqual(result.focusedDuration, 10)
        XCTAssertEqual(result.pausedDuration, 2)
        XCTAssertEqual(result.pauseCount, 1, "the automatic confirmation pause is telemetry")
    }

    func testCancelConfirmationConditionallyResumesOnlyItsOwnPause() async throws {
        let taskID = UUID()
        try writeTaskFile("Conditional resume task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)

        XCTAssertTrue(model.beginEndSessionConfirmation())
        clock.advance(by: 30)
        model.cancelEndSessionConfirmation()
        XCTAssertEqual(model.sessionState, .running, "the flow resumes its automatic pause")
        clock.advance(by: 30)
        XCTAssertEqual(model.focusedSeconds, 30, accuracy: 1e-9)

        try model.pauseSession()
        XCTAssertTrue(model.beginEndSessionConfirmation())
        clock.advance(by: 30)
        model.cancelEndSessionConfirmation()
        XCTAssertEqual(model.sessionState, .paused, "a pre-existing pause stays paused")
        XCTAssertEqual(model.focusedSeconds, 30, accuracy: 1e-9)

        let result = try model.endSession()
        XCTAssertEqual(result.pauseCount, 2, "only the first confirmation added a pause")
    }

    func testEndSessionCapturesEndInstantSnapshotIntoPhase() async throws {
        let taskID = UUID()
        try writeTaskFile("Capture task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)

        let result = try model.endSession()

        guard case .endingSession(let retained, let snapshot, let retainedContext) = model.appPhase
        else {
            XCTFail("expected .endingSession(...), got \(model.appPhase)")
            return
        }
        XCTAssertEqual(retained, result)
        XCTAssertEqual(retainedContext, context)
        XCTAssertEqual(snapshot.sessionID, result.sessionID)
        XCTAssertEqual(snapshot.taskID, taskID)
        XCTAssertEqual(snapshot.startedAt, result.startedAt)
        XCTAssertEqual(snapshot.duration, 1500, accuracy: 1e-9)
        XCTAssertEqual(snapshot.isPaused, false, "running-at-end")
        XCTAssertEqual(snapshot.accumulatedFocusedSeconds, 1500, accuracy: 1e-9)
        XCTAssertEqual(snapshot.accumulatedPausedSeconds, 300, accuracy: 1e-9)
        XCTAssertEqual(snapshot.pauseCount, 1)
    }

    // MARK: - Cancel, running-at-end (issue #29 modal-time mechanic)

    func testCancelRunningAtEndRestoresRunningAndModalTimeCountsNothing() async throws {
        let taskID = UUID()
        try writeTaskFile("Resume task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)
        let result = try model.endSession()

        // The modal sits open for 123 s of modal time — the engine is idle,
        // nothing accumulates anywhere.
        clock.advance(by: 123)

        let outcome = try model.cancelEndOfSession()

        // Typed outcome + phase + state: restored RUNNING (faithful phase).
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(model.appPhase, .timerView(context))
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertTrue(model.isSessionActive)
        // The re-anchor absorbs the modal time: focused is exactly the
        // captured accumulator, the 123 s counted as NOTHING.
        XCTAssertEqual(model.focusedSeconds, 1500, accuracy: 1e-9)
        // The clock continues: focused GROWS after the cancel.
        clock.advance(by: 60)
        XCTAssertEqual(model.focusedSeconds, 1560, accuracy: 1e-9)

        // A later real end: same session identity, correct final totals.
        let second = try model.endSession()
        XCTAssertEqual(second.sessionID, result.sessionID, "same session_id")
        XCTAssertEqual(second.startedAt, result.startedAt, "same started_at")
        XCTAssertEqual(second.pauseCount, 1, "pause count carried verbatim")
        XCTAssertEqual(second.focusedDuration, 26, "1560 s → 26 min")
        XCTAssertEqual(second.pausedDuration, 5, "300 s → 5 min")
    }

    // MARK: - Cancel, paused-at-end (issue #29 modal-time mechanic)

    func testCancelPausedAtEndRestoresPausedAndModalTimeLandsInPaused() async throws {
        let taskID = UUID()
        try writeTaskFile("Paused end task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)
        // 10 min focus, then pause — ending FROM the open pause.
        clock.advance(by: 600)
        try model.pauseSession()
        clock.advance(by: 300)
        let result = try model.endSession()
        XCTAssertEqual(result.focusedDuration, 10)
        XCTAssertEqual(result.pausedDuration, 5)
        XCTAssertEqual(result.pauseCount, 1)

        // Modal time while idle: 180 s that must count as nothing.
        clock.advance(by: 180)

        let outcome = try model.cancelEndOfSession()

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(model.appPhase, .timerView(context))
        XCTAssertEqual(model.sessionState, .paused, "restored PAUSED (UI shows Resume)")
        XCTAssertTrue(model.isSessionActive)

        // Focused is frozen while paused — the restored-open-pause time
        // never leaks into focused (the pinned invariant).
        clock.advance(by: 120)
        XCTAssertEqual(model.focusedSeconds, 600, accuracy: 1e-9, "focused frozen")

        // The user resumes via the normal Pause/Resume button; the frozen
        // modal time lands in PAUSED, and focused grows again.
        try model.resumeSession()
        clock.advance(by: 240)
        XCTAssertEqual(model.focusedSeconds, 840, accuracy: 1e-9)

        let second = try model.endSession()
        XCTAssertEqual(second.sessionID, result.sessionID)
        XCTAssertEqual(second.startedAt, result.startedAt)
        XCTAssertEqual(second.pauseCount, 1)
        XCTAssertEqual(second.focusedDuration, 14, "(600 + 240) s → 14 min")
        XCTAssertEqual(second.pausedDuration, 7, "(300 + 120) s → 7 min")
    }

    // MARK: - No log on cancel (issue #29)

    func testCancelWritesNoLogAndParseBackDayIsEmpty() async throws {
        let taskID = UUID()
        try writeTaskFile("No log task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)
        let result = try model.endSession()
        _ = try model.cancelEndOfSession()

        // Cancel never appends: the end-day file holds no session (the
        // parse-back the issue pins).
        let sessions = try await parseBackSessions(forDayOf: result.endedAt)
        XCTAssertTrue(sessions.isEmpty, "nothing was written on cancel")
        XCTAssertTrue(model.isSessionActive, "the session is live again, not logged")
    }

    // MARK: - Exactly-once logging after a cancel (issue #29)

    func testCancelThenRealEndSubmitLogsExactlyOnceWithFinalTotals() async throws {
        let taskID = UUID()
        try writeTaskFile("Once task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)
        let first = try model.endSession()

        clock.advance(by: 123)  // modal time — counts as nothing
        _ = try model.cancelEndOfSession()
        clock.advance(by: 60)  // the session keeps running

        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 4
        form.energyRating = 3
        let second = try model.endSession()
        // The engine's honest totals: pre-cancel 1500 s + post-cancel 60 s
        // (the 123 s modal gap counts as NOTHING in the engine).
        XCTAssertEqual(second.focusedDuration, 26)
        XCTAssertEqual(second.pausedDuration, 5)
        _ = try await model.submitEndOfSession(form)

        let sessions = try await parseBackSessions(forDayOf: second.endedAt)
        XCTAssertEqual(sessions.count, 1, "exactly ONE session entry")
        let logged = try XCTUnwrap(sessions.first)
        XCTAssertEqual(logged.sessionID, second.sessionID)
        XCTAssertEqual(logged.sessionID, first.sessionID, "the cancel resumed, not restarted")
        XCTAssertEqual(logged.startedAt, second.startedAt)
        XCTAssertEqual(logged.pausedDuration, 5)
        XCTAssertEqual(logged.pauseCount, 1)
        // The log's focused field is the #27-pinned span reconciliation
        // (span_min − paused_min), unchanged by this issue: the span
        // (1983 s → 33 min) includes the modal gap the engine correctly
        // ignores, so the reconciled focused is 33 − 5 = 28 — the
        // documented span/engine disagreement, composed per #27.
        XCTAssertEqual(logged.focusedDuration, 28, "33-min span − 5 paused")
    }

    // MARK: - Autosave re-arm (issue #29, per the #13 cadence)

    func testAutosaveReArmedAfterCancelAndTickRepersistsSnapshot() async throws {
        let taskID = UUID()
        try writeTaskFile("Autosave task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)
        let result = try model.endSession()

        // Clear-on-end cancelled the tick and wiped the snapshot.
        XCTAssertNil(scheduler.pendingInterval, "no tick armed after end")
        XCTAssertNil(try onDiskSnapshot(), "clear-on-end wiped the snapshot")

        clock.advance(by: 100)
        _ = try model.cancelEndOfSession()

        // Restore re-arms the autosave chain (the #13 restore contract).
        XCTAssertEqual(
            scheduler.pendingInterval, AppModel.autosaveIntervalSeconds,
            "the autosave cadence is re-armed")
        // The restore leaves the stored file untouched (the #13 contract) —
        // the snapshot is re-persisted by the cadence itself.
        XCTAssertNil(try onDiskSnapshot(), "no immediate save on restore")

        // The next tick persists the restored session.
        scheduler.firePendingTick()
        let persisted = try XCTUnwrap(try onDiskSnapshot(), "the tick re-persisted")
        XCTAssertEqual(persisted.sessionID, result.sessionID)
        XCTAssertEqual(persisted.accumulatedFocusedSeconds, 1500, accuracy: 1e-9)

        // And the chain keeps re-arming.
        XCTAssertEqual(scheduler.pendingInterval, AppModel.autosaveIntervalSeconds)
    }

    // MARK: - Guards across the cancel (issue #29 pinned ordering)

    func testStartsRefusedWhileModalUpThenAfterCancelViaAlreadyActiveGuard()
        async throws
    {
        let endedID = UUID()
        let otherID = UUID()
        try writeTaskFile("Guard ended task", id: endedID, in: vaultURL)
        try writeTaskFile("Guard other task", id: otherID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: endedID)
        try runPinnedTelemetry(on: model)
        _ = try model.endSession()

        // While the modal is up, the .sessionEndingUnresolved refusal applies.
        let whileEnding = try await model.startSession(taskID: otherID)
        XCTAssertEqual(whileEnding, .refused(.sessionEndingUnresolved))

        _ = try model.cancelEndOfSession()

        // After Cancel the restore happened BEFORE the phase swap, so starts
        // refuse via the ordinary already-active-session guard — proving the
        // engine is live again (no instant where the flow was unguarded).
        let afterCancel = try await model.startSession(taskID: otherID)
        XCTAssertEqual(afterCancel, .refused(.sessionAlreadyActive))
        XCTAssertEqual(model.appPhase, .timerView(context))
        XCTAssertTrue(model.isSessionActive)
        XCTAssertEqual(model.sessionState, .running)
    }

    // MARK: - Snapshot dropped on submit AND on discard (issue #29)

    func testSnapshotDroppedOnSubmitCancelIsTypedNoOp() async throws {
        let taskID = UUID()
        try writeTaskFile("Drop on submit task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)
        let result = try model.endSession()

        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 3
        form.energyRating = 3
        _ = try await model.submitEndOfSession(form)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))

        // The snapshot went with the phase payload: nothing restorable.
        let outcome = try model.cancelEndOfSession()
        XCTAssertEqual(outcome, .noEndingSession, "typed no-session outcome")
        XCTAssertFalse(model.isSessionActive)
        XCTAssertEqual(model.sessionState, .idle)
        let sessions = try await parseBackSessions(forDayOf: result.endedAt)
        XCTAssertEqual(sessions.count, 1, "the submission logged, the cancel did nothing")
    }

    func testSnapshotDroppedOnDiscardCancelIsTypedNoOp() async throws {
        let taskID = UUID()
        try writeTaskFile("Drop on discard task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)
        let result = try model.endSession()

        model.discardEndOfSession()
        XCTAssertEqual(model.appPhase, .tasksView)

        let outcome = try model.cancelEndOfSession()
        XCTAssertEqual(outcome, .noEndingSession, "typed no-session outcome")
        XCTAssertFalse(model.isSessionActive)
        let sessions = try await parseBackSessions(forDayOf: result.endedAt)
        XCTAssertTrue(sessions.isEmpty, "nothing was ever written")
    }

    func testCancelOutsideEndingPhaseIsTypedNoOp() async throws {
        let model = await makeConfiguredModel()
        let outcome = try model.cancelEndOfSession()
        XCTAssertEqual(outcome, .noEndingSession)
        XCTAssertEqual(model.appPhase, .tasksView, "untouched")
        XCTAssertFalse(model.isSessionActive)
    }

    // MARK: - Mini mode + session number (issue #29 documented choices)

    func testCancelLandsFullTimerAndDoesNotRefetchSessionNumber() async throws {
        let taskID = UUID()
        try writeTaskFile("Mini cancel task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        model.recordSessionNumberToday(3)
        model.collapseToMiniTimer()
        XCTAssertTrue(model.isMiniTimerActive)
        try runPinnedTelemetry(on: model)
        _ = try model.endSession()
        XCTAssertFalse(model.isMiniTimerActive, "end closes the panel (any path)")
        XCTAssertNil(model.sessionNumberToday, "end cleared the #20 snapshot")

        _ = try model.cancelEndOfSession()

        // Engineer's choice (documented): Cancel always lands on the FULL
        // timer — the pre-end mini flag is not restored; the user
        // re-collapses from the full timer if desired.
        XCTAssertFalse(model.isMiniTimerActive, "cancel lands full, never re-collapses")
        // Not re-fetched (already correct — documented): the model touches
        // nothing; the #21 view-driven on-appear fetch of the restored
        // .timerView owns the refresh.
        XCTAssertNil(model.sessionNumberToday, "no model-side refetch on cancel")
        XCTAssertEqual(model.sessionState, .running)
    }
}
