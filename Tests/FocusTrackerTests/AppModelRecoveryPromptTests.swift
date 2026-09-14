import XCTest
@testable import FocusTracker

// File-local aliases keep the phase assertions readable.
private typealias AppPhase = AppModel.AppPhase

/// Tests for the recovery prompt (issue #36): with a persisted snapshot, the
/// bootstrap surfaces the ONE phase-driven prompt (`.recoveryPrompt`) on
/// every launch path with a pending recovery — task title resolved from the
/// snapshot's task ID (unknown ID → the generic wording) plus the focused
/// time; Resume restores the engine per #13/#33 (`.timerView`, autosave
/// re-armed, expired snapshots restore at their expiry-instant state and do
/// not instantly re-end) and a later real end logs correctly (parse-back);
/// Discard clears the snapshot file, logs nothing and re-allows starts; the
/// #19 `.pendingRecoveryUnresolved` start refusal remains as the defensive
/// backstop while the prompt is up. Temp-dir persistence dir + temp-dir
/// fixture copy per the established pattern; the FakeClock drives every
/// duration.
@MainActor
final class AppModelRecoveryPromptTests: XCTestCase {

    // MARK: - Test doubles (the same seams the other AppModel tests use)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(by interval: TimeInterval) {
            monotonicSeconds += interval
            wallClockNow = wallClockNow.addingTimeInterval(interval)
        }
    }

    private final class ManualTickScheduler: ActiveSessionTickScheduler,
        @unchecked Sendable {
        private let lock = NSLock()
        private var interval: TimeInterval?

        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {
            lock.withLock { self.interval = interval }
        }

        func cancel() {
            lock.withLock { interval = nil }
        }

        var pendingInterval: TimeInterval? { lock.withLock { interval } }
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
    private var scheduler: ManualTickScheduler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "RecoveryPromptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "RecoveryPromptTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
        clock = FakeClock()
        scheduler = ManualTickScheduler()
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
        let model = AppModel(
            settings: settings, persistenceDirectory: persistenceDirectory,
            scheduler: scheduler, sessionClock: clock)
        await model.bootstrap()
        return model
    }

    private func makeSnapshot(
        taskID: UUID, duration: TimeInterval = 1500,
        focusedSeconds: TimeInterval = 600, isPaused: Bool = false
    ) -> ActiveSessionSnapshot {
        ActiveSessionSnapshot(
            sessionID: UUID(), taskID: taskID, duration: duration,
            startedAt: clock.wallClockNow,
            accumulatedFocusedSeconds: focusedSeconds,
            accumulatedPausedSeconds: isPaused ? 60 : 0,
            pauseCount: isPaused ? 1 : 0, isPaused: isPaused,
            segmentStartMonotonic: 42)
    }

    private func seedSnapshot(_ snapshot: ActiveSessionSnapshot) throws {
        try FileActiveSessionPersistence(directory: persistenceDirectory)
            .save(snapshot)
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

    private func makeForm() -> EndOfSessionFormState {
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 4
        form.energyRating = 3
        return form
    }

    // MARK: - Prompt phase presence on bootstrap (the ONE presentation)

    func testBootstrapWithSnapshotSurfacesRecoveryPromptPhase() async throws {
        let taskID = UUID()
        try writeTaskFile("Recovery target task", id: taskID, in: vaultURL)
        let snapshot = makeSnapshot(taskID: taskID)
        try seedSnapshot(snapshot)

        let model = await makeConfiguredModel()

        // The prompt IS the phase: presented by the shell for exactly this
        // phase, with the pending state retained (nothing restored yet).
        XCTAssertEqual(model.pendingSessionRecovery, snapshot)
        guard case .recoveryPrompt(let prompted, let context) = model.appPhase else {
            XCTFail("expected .recoveryPrompt, got \(model.appPhase)")
            return
        }
        XCTAssertEqual(prompted, snapshot)
        // The snapshot's task ID resolves in the loaded inventory: the real
        // title, the honest focused-time readout's source.
        XCTAssertEqual(context.taskID, taskID)
        XCTAssertEqual(context.title, "Recovery target task")
        XCTAssertEqual(model.sessionState, .idle, "nothing restored before the choice")
        XCTAssertFalse(model.isSessionActive)
    }

    func testBootstrapWithoutSnapshotHasNoPrompt() async throws {
        let model = await makeConfiguredModel()

        XCTAssertNil(model.pendingSessionRecovery)
        XCTAssertEqual(model.appPhase, .tasksView)
    }

    // MARK: - Unknown task ID → generic wording

    func testUnknownTaskIDResolvesToGenericWording() async throws {
        let unknown = UUID()
        try seedSnapshot(makeSnapshot(taskID: unknown))

        let model = await makeConfiguredModel()

        guard case .recoveryPrompt(_, let context) = model.appPhase else {
            XCTFail("expected .recoveryPrompt, got \(model.appPhase)")
            return
        }
        XCTAssertEqual(context.taskID, unknown)
        XCTAssertEqual(
            context.title, AppModel.recoveredSessionGenericTitle,
            "a deleted/absent target shows the honest generic wording")
        XCTAssertEqual(context.parentTaskTitle, nil)
    }

    // MARK: - Resume path

    func testResumeRestoresEngineSwapsToTimerViewAndReArmsAutosave()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Recovery resume task", id: taskID, in: vaultURL)
        var snapshot = makeSnapshot(taskID: taskID, focusedSeconds: 600)
        // Wall-span physics stay honest: the session STARTED 600 s ago (the
        // seeded accumulators cover exactly that), so the end's wall span is
        // 720 s and the #27 whole-minute reconciliation has room for the
        // 12 focused minutes the parse-back asserts.
        snapshot.startedAt = clock.wallClockNow.addingTimeInterval(-600)
        try seedSnapshot(snapshot)
        let model = await makeConfiguredModel()

        let outcome = try model.restorePendingSession()

        XCTAssertEqual(outcome, .restored)
        XCTAssertNil(model.pendingSessionRecovery)
        XCTAssertTrue(model.isSessionActive, "the engine is restored")
        XCTAssertEqual(model.sessionState, .running, "as the snapshot carries it")
        XCTAssertEqual(
            scheduler.pendingInterval, AppModel.autosaveIntervalSeconds,
            "the autosave chain is re-armed by the restore")
        XCTAssertEqual(
            model.focusedSeconds, 600, accuracy: 1e-9,
            "timing continues from the snapshot's accumulators")
        let context = AppModel.SessionContext(
            taskID: taskID, title: "Recovery resume task",
            parentTaskTitle: nil, project: nil, categories: [Category(name: "Testing")])
        XCTAssertEqual(model.appPhase, .timerView(context))

        // A later REAL end logs correctly (parse-back): 600 s seeded + 120 s
        // advanced = 12 focused minutes, linked to the same task.
        clock.advance(by: 120)
        let result = try model.endSession()
        XCTAssertEqual(result.taskID, taskID)
        let submission = try await model.submitEndOfSession(makeForm())
        XCTAssertEqual(submission, .success)
        let store = try XCTUnwrap(model.dailyLogStore)
        let logs = try await store.sessions(
            for: taskID, on: AppModel.logDay(forEndedAt: result.endedAt))
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.taskID, taskID)
        XCTAssertEqual(logs.first?.focusedDuration, 12)
        XCTAssertEqual(logs.first?.pauseCount, 0)
    }

    func testResumeOfPausedSnapshotRestoresPaused() async throws {
        let taskID = UUID()
        try writeTaskFile("Recovery paused task", id: taskID, in: vaultURL)
        try seedSnapshot(makeSnapshot(taskID: taskID, isPaused: true))
        let model = await makeConfiguredModel()

        XCTAssertEqual(try model.restorePendingSession(), .restored)

        XCTAssertEqual(model.sessionState, .paused, "restored paused, never running")
        XCTAssertTrue(model.isSessionActive)
        guard case .timerView = model.appPhase else {
            XCTFail("expected .timerView, got \(model.appPhase)")
            return
        }
    }

    func testResumeOfExpiredSnapshotRestoresAtExpiryInstantWithoutReEnding()
        async throws
    {
        // The #33 interplay: an expired snapshot restores AT its expiry
        // state (focused == duration) and the user's explicit resume marks
        // the expiry handled — the watcher must not instantly re-end it.
        let taskID = UUID()
        try writeTaskFile("Recovery expired task", id: taskID, in: vaultURL)
        try seedSnapshot(
            makeSnapshot(taskID: taskID, duration: 1500, focusedSeconds: 1500))
        let model = await makeConfiguredModel()

        XCTAssertEqual(try model.restorePendingSession(), .restored)
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertEqual(
            model.focusedSeconds, 1500, accuracy: 1e-9,
            "the expiry-instant accumulators are carried verbatim")

        model.evaluateSessionExpiry()
        XCTAssertTrue(model.isSessionActive, "no instant re-end")
        guard case .timerView = model.appPhase else {
            XCTFail("expected .timerView to stay, got \(model.appPhase)")
            return
        }
    }

    // MARK: - Discard path

    func testDiscardClearsSnapshotLogsNothingAndAllowsStarts() async throws {
        let taskID = UUID()
        try writeTaskFile("Recovery discard task", id: taskID, in: vaultURL)
        let startTarget = UUID()
        try writeTaskFile("Recovery next task", id: startTarget, in: vaultURL)
        let snapshot = makeSnapshot(taskID: taskID)
        try seedSnapshot(snapshot)
        let model = await makeConfiguredModel()
        XCTAssertNotNil(model.pendingSessionRecovery)

        XCTAssertEqual(model.discardPendingSession(), .discarded)

        // Snapshot file gone (the #13 parse-back of the persistence dir)…
        XCTAssertNil(
            try FileActiveSessionPersistence(directory: persistenceDirectory).load())
        // …the phase is Tasks (the prompt's underneath screen, so nothing
        // visibly jumps), nothing is logged for the discarded session, and
        // a fresh launch would surface no pending recovery.
        XCTAssertEqual(model.appPhase, .tasksView)
        let store = try XCTUnwrap(model.dailyLogStore)
        let logs = try await store.sessions(
            for: taskID, on: AppModel.logDay(forEndedAt: snapshot.startedAt))
        XCTAssertTrue(logs.isEmpty, "a discarded session is never logged")
        let fresh = AppModel(
            settings: settings, persistenceDirectory: persistenceDirectory,
            scheduler: scheduler, sessionClock: clock)
        await fresh.bootstrap()
        XCTAssertNil(fresh.pendingSessionRecovery)

        // Starts are allowed again: a normal session runs on Tasks' terms.
        let outcome = try await model.startSession(taskID: startTarget)
        guard case .started = outcome else {
            XCTFail("expected .started(...), got \(outcome)")
            return
        }
        XCTAssertEqual(
            model.appPhase,
            .timerView(AppModel.SessionContext(
                taskID: startTarget, title: "Recovery next task",
                parentTaskTitle: nil, project: nil,
                categories: [Category(name: "Testing")])))
    }

    // MARK: - The #19 refusal backstop (defensive, practically unreachable)

    func testStartRefusalBackstopStillFiresWhilePromptIsUp() async throws {
        let taskID = UUID()
        try writeTaskFile("Recovery backstop task", id: taskID, in: vaultURL)
        try seedSnapshot(makeSnapshot(taskID: taskID))
        let model = await makeConfiguredModel()

        // With the prompt up, the model-level refusal still holds (the UI
        // cannot even reach it — the prompt blocks the app — but the guard
        // is unchanged and compiles/behaves as before).
        let attempt = try await model.startSession(taskID: taskID)
        XCTAssertEqual(attempt, .refused(.pendingRecoveryUnresolved))
        XCTAssertEqual(model.pendingSessionRecovery?.taskID, taskID)
        guard case .recoveryPrompt = model.appPhase else {
            XCTFail("the refusal touched nothing — prompt stays")
            return
        }

        // After the user resolves the prompt, the same start succeeds.
        XCTAssertEqual(model.discardPendingSession(), .discarded)
        let resolved = try await model.startSession(taskID: taskID)
        guard case .started = resolved else {
            XCTFail("expected .started(...), got \(resolved)")
            return
        }
    }
}
