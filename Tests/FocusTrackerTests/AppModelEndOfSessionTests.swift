import XCTest
@testable import FocusTracker

// File-local aliases keep the #22 nested-type assertions readable.
private typealias SessionContext = AppModel.SessionContext

/// Tests for the #22 `AppModel` end-of-session flow (issue #22): the
/// confirm step (result retained, `.endingSession` phase, session state
/// cleared, coordinator clear-on-end verified), the pinned submission order
/// (log FIRST to the END day, then §6.5 completion), the typed outcomes
/// (success / log-append failure retaining the ending state / completion
/// failure after a successful log), the submission-required refusals
/// (`.sessionEndingUnresolved`, `setVaultPath`), notes-nil-in-file, and the
/// pure end-day selection helper. Temp-dir fixture copy per the established
/// pattern; the FakeClock drives the pinned 10/5/15 telemetry so the append
/// arithmetic invariant holds exactly (25 focused + 5 paused == 35-min span).
@MainActor
final class AppModelEndOfSessionTests: XCTestCase {

    // MARK: - Test doubles (same seams as the #13/#14/#19 tests)

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

    private final class ManualTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
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

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EndOfSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "EndOfSessionTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
        clock = FakeClock()
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
            scheduler: ManualTickScheduler(), sessionClock: clock)
        await model.bootstrap()
        return model
    }

    /// Writes a task file with an arbitrary status and (optionally nested)
    /// subtasks, mirroring the fixture schema's exact shape.
    private func writeTaskFile(
        _ title: String, id: UUID, status: TaskStatus = .toDo,
        subtasks: [SubtaskItem] = [], in vault: URL
    ) throws {
        var lines: [String] = [
            "---",
            "id: \(id.uuidString)",
            "title: \(title)",
            "status: \(status.rawValue)",
            "categories:",
            "  - Testing",
        ]
        if !subtasks.isEmpty {
            lines.append("subtasks:")
            lines.append(contentsOf: Self.subtaskYAML(subtasks, indent: "  "))
        }
        lines.append("---")
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(
            to: vault.appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent("\(title).md"),
            atomically: true, encoding: .utf8)
    }

    private static func subtaskYAML(_ subtasks: [SubtaskItem], indent: String) -> [String] {
        var lines: [String] = []
        for subtask in subtasks {
            lines.append("\(indent)- id: \(subtask.id.uuidString)")
            lines.append("\(indent)  title: \(subtask.title)")
            lines.append("\(indent)  status: \(subtask.status.rawValue)")
            if !subtask.children.isEmpty {
                lines.append("\(indent)  subtasks:")
                lines.append(
                    contentsOf: subtaskYAML(subtask.children, indent: indent + "  "))
            }
        }
        return lines
    }

    /// The vault's on-disk state, parsed back through a fresh store (never
    /// the model's in-memory copy).
    private func parseBackTask(
        id: UUID, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> TaskItem {
        let store = VaultStore(vaultURL: vaultURL)
        guard case .loaded(let inventory) = await store.load() else {
            XCTFail("expected a loaded vault on parse-back", file: file, line: line)
            throw TestFailure()
        }
        return try XCTUnwrap(
            inventory.tasks.first { $0.id == id }, "task on disk",
            file: file, line: line)
    }

    /// The logged session parsed back from the END-day file on disk (a
    /// fresh store — the parse-back the issue pins).
    private func parseBackSession(
        _ result: FocusSessionResult, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> FocusSessionLog {
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(for: AppModel.logDay(forEndedAt: result.endedAt))
        return try XCTUnwrap(
            day.sessions.first { $0.sessionID == result.sessionID },
            "session present in the end-day file", file: file, line: line)
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

    /// The #29 `.endingSession` phase carries the end-instant snapshot
    /// between the result and the context; these pre-#29 assertions match
    /// result + context and verify the snapshot's session identity (its
    /// exact fields are pinned by the #29 tests).
    private func assertEndingPhase(
        _ phase: AppModel.AppPhase, result: FocusSessionResult,
        context: SessionContext,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .endingSession(let retained, let snapshot, let retainedContext) = phase else {
            XCTFail("expected .endingSession(...), got \(phase)", file: file, line: line)
            return
        }
        XCTAssertEqual(retained, result, file: file, line: line)
        XCTAssertEqual(retainedContext, context, file: file, line: line)
        XCTAssertEqual(
            snapshot.sessionID, result.sessionID, "snapshot identity",
            file: file, line: line)
    }

    private func startRunningSession(
        on model: AppModel, taskID: UUID, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SessionContext {
        let outcome = try await model.startSession(taskID: taskID)
        guard case .started(let context) = outcome else {
            XCTFail("expected .started(...), got \(outcome)", file: file, line: line)
            throw TestFailure()
        }
        return context
    }

    /// The pinned 10/5/15 telemetry: 10 min focus, 5 min pause, 15 min
    /// focus → focused 25, paused 5, span 35 min (the append invariant
    /// holds exactly).
    private func runPinnedTelemetry(on model: AppModel) throws {
        clock.advance(by: 600)
        try model.pauseSession()
        clock.advance(by: 300)
        try model.resumeSession()
        clock.advance(by: 900)
    }

    @discardableResult
    private func runSessionToEnd(
        on model: AppModel, taskID: UUID, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (result: FocusSessionResult, context: SessionContext) {
        let context = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)
        let result = try model.endSession()
        return (result, context)
    }

    // MARK: - Confirm step (issue criteria 2–4)

    func testConfirmEndRetainsResultEntersEndingPhaseAndClearsSessionState()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("End flow task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)
        model.recordSessionNumberToday(7)
        model.collapseToMiniTimer()
        XCTAssertTrue(model.isMiniTimerActive, "collapsed before ending")
        try runPinnedTelemetry(on: model)

        let result = try model.endSession()

        // The engine result is retained with the pinned 10/5/15 telemetry.
        XCTAssertEqual(result.taskID, taskID)
        XCTAssertEqual(result.focusedDuration, 25)
        XCTAssertEqual(result.pausedDuration, 5)
        XCTAssertEqual(result.pauseCount, 1)
        // The phase holds the result PLUS the session context.
        assertEndingPhase(model.appPhase, result: result, context: context)
        // sessionState is idle from the confirm instant; engine closed.
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertFalse(model.isSessionActive)
        // Mini flag cleared (panel closes; the main window restores with
        // the modal) and the session-number snapshot cleared.
        XCTAssertFalse(model.isMiniTimerActive)
        XCTAssertNil(model.sessionNumberToday)
        // Clear-on-end verified: the coordinator wiped the on-disk snapshot.
        let snapshot = try FileActiveSessionPersistence(directory: persistenceDirectory)
            .load()
        XCTAssertNil(snapshot)
    }

    func testEndSessionOutsideTimerPhaseIsTypedError() async throws {
        let model = await makeConfiguredModel()
        XCTAssertThrowsError(try model.endSession()) { error in
            XCTAssertEqual(error as? FocusSessionError, .noActiveSession)
        }
        XCTAssertEqual(model.appPhase, .tasksView, "nothing changed")
    }

    // MARK: - Full success (issue criterion 16: ALL §13 fields, Done on disk, bubble)

    func testSubmitYesWritesLogWithAllFieldsAndBubblesParentCompletion() async throws {
        let parentID = UUID()
        let childID = UUID()
        try writeTaskFile(
            "Bubble parent", id: parentID, status: .toDo,
            subtasks: [SubtaskItem(id: childID, title: "Only child")], in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, _) = try await runSessionToEnd(on: model, taskID: childID)

        let outcome = try await model.submitEndOfSession(
            makeForm(completed: .yes, focus: 4, energy: 2, notes: "Deep work."))

        XCTAssertEqual(outcome, .success)
        // Issue #23: the flow's exit stops at the post-session choice.
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))
        XCTAssertEqual(model.sessionState, .idle)

        // Day-file parse-back: ALL §13 fields with correct values.
        let logged = try await parseBackSession(result)
        XCTAssertEqual(logged.sessionID, result.sessionID)
        XCTAssertEqual(logged.taskID, childID)
        XCTAssertEqual(logged.startedAt, result.startedAt)
        XCTAssertEqual(logged.endedAt, result.endedAt)
        XCTAssertEqual(logged.focusedDuration, 25)
        XCTAssertEqual(logged.pauseCount, 1)
        XCTAssertEqual(logged.pausedDuration, 5)
        XCTAssertEqual(logged.focusRating, 4)
        XCTAssertEqual(logged.energyRating, 2)
        XCTAssertEqual(logged.taskCompleted, true)
        XCTAssertEqual(logged.notes, "Deep work.")

        // §6.5 completion on disk: the only child Done → the parent bubbles.
        let onDisk = try await parseBackTask(id: parentID)
        XCTAssertEqual(onDisk.status, .done, "parent bubble applied on disk")
        let childOnDisk = try XCTUnwrap(onDisk.subtasks.first { $0.id == childID })
        XCTAssertEqual(childOnDisk.status, .done)

        // The submission added no snapshot and cleared nothing: still none.
        let snapshot = try FileActiveSessionPersistence(directory: persistenceDirectory)
            .load()
        XCTAssertNil(snapshot)
    }

    // MARK: - No path (issue criterion 16: log written, status untouched)

    func testSubmitNoWritesLogButLeavesTaskStatusUntouched() async throws {
        let taskID = UUID()
        try writeTaskFile("No path task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, _) = try await runSessionToEnd(on: model, taskID: taskID)

        let outcome = try await model.submitEndOfSession(
            makeForm(completed: .no, focus: 3, energy: 3, notes: "Not finished"))

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))
        let logged = try await parseBackSession(result)
        XCTAssertEqual(logged.taskCompleted, false)
        XCTAssertEqual(logged.notes, "Not finished")
        // The task status is untouched on disk: still In Progress.
        let onDisk = try await parseBackTask(id: taskID)
        XCTAssertEqual(onDisk.status, .inProgress)
    }

    // MARK: - Log-append failure retains the ending state (issue criterion 13)

    func testLogAppendFailureRetainsEndingStateForRetryThenRetrySucceeds()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Retry task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, context) = try await runSessionToEnd(on: model, taskID: taskID)

        // Inject the append failure: replace `Logs/` with a regular FILE,
        // so the append's directory creation fails typed (nothing
        // written). The fixture copy ships with a Logs/ directory —
        // removed first.
        let logsDirectory = vaultURL.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.removeItem(at: logsDirectory)
        let logsPath = vaultURL.appendingPathComponent("Logs", isDirectory: false)
        let obstruction = Data("not a directory".utf8)
        try obstruction.write(to: logsPath)

        let outcome = try await model.submitEndOfSession(makeForm(completed: .no))

        guard case .logAppendFailed(.directoryCreationFailed(let path, _)) = outcome else {
            XCTFail("expected .logAppendFailed(...), got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(
            path,
            vaultURL.appendingPathComponent("Logs", isDirectory: true)
                .path(percentEncoded: false))
        // The ending state is RETAINED (the modal stays up for retry): the
        // in-memory result is the only copy of the session.
        assertEndingPhase(model.appPhase, result: result, context: context)
        XCTAssertFalse(model.isSessionActive)
        // Nothing was written — the obstruction is untouched.
        XCTAssertEqual(try Data(contentsOf: logsPath), obstruction)

        // Remove the obstruction; the SAME ending state retries to success.
        try FileManager.default.removeItem(at: logsPath)
        let retry = try await model.submitEndOfSession(makeForm(completed: .no))
        XCTAssertEqual(retry, .success)
        XCTAssertEqual(
            model.appPhase, .postSessionChoice(completionFailure: nil),
            "retry completes the flow (issue #23: at the choice)")
        let logged = try await parseBackSession(result)
        XCTAssertEqual(logged.sessionID, result.sessionID)
        XCTAssertEqual(logged.taskCompleted, false)
    }

    // MARK: - Issue #27 repro: sub-minute drift appends and parses back

    func testReproSubMinuteDriftAppendsWithReconciledMinutes() async throws {
        let taskID = UUID()
        try writeTaskFile("Drift task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        // The user-reported repro: 55 s focus, 11 s pause → a 66 s span.
        clock.advance(by: 55)
        try model.pauseSession()
        clock.advance(by: 11)
        try model.resumeSession()
        let result = try model.endSession()
        XCTAssertEqual(result.focusedDuration, 1, "nearest(55/60), half away from zero")
        XCTAssertEqual(result.pausedDuration, 0, "nearest(11/60)")

        // Under #11's original exact-second append check this submission
        // failed and trapped the modal; with #27's reconciliation + amended
        // granularity it appends successfully.
        let outcome = try await model.submitEndOfSession(makeForm(completed: .no))
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))

        // Parse-back: focused 1 / paused 0.
        let logged = try await parseBackSession(result)
        XCTAssertEqual(logged.focusedDuration, 1)
        XCTAssertEqual(logged.pausedDuration, 0)
    }

    // MARK: - Issue #27 escape hatch: discard the unsubmitted session

    func testDiscardDropsEndingStateAndWritesNothing() async throws {
        let taskID = UUID()
        try writeTaskFile("Discard task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, context) = try await runSessionToEnd(on: model, taskID: taskID)
        assertEndingPhase(model.appPhase, result: result, context: context)

        model.discardEndOfSession()

        XCTAssertEqual(model.appPhase, .tasksView)
        XCTAssertFalse(model.isSessionActive)
        // Nothing appended to any log: the end-day file holds no session.
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(for: AppModel.logDay(forEndedAt: result.endedAt))
        XCTAssertTrue(day.sessions.isEmpty, "nothing was written on discard")
        // The snapshot stays cleared: still none on disk.
        let snapshot = try FileActiveSessionPersistence(directory: persistenceDirectory)
            .load()
        XCTAssertNil(snapshot)
    }

    func testDiscardAfterAppendFailureEscapesTheTrappedModal() async throws {
        let taskID = UUID()
        try writeTaskFile("Trap task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, context) = try await runSessionToEnd(on: model, taskID: taskID)

        // Inject the deterministic append failure (the retry test's seam):
        // `Logs/` becomes a regular file, so the append can never succeed.
        let logsDirectory = vaultURL.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.removeItem(at: logsDirectory)
        let logsPath = vaultURL.appendingPathComponent("Logs", isDirectory: false)
        let obstruction = Data("not a directory".utf8)
        try obstruction.write(to: logsPath)

        let outcome = try await model.submitEndOfSession(makeForm(completed: .no))
        guard case .logAppendFailed = outcome else {
            return XCTFail("expected .logAppendFailed, got \(String(describing: outcome))")
        }
        // Trapped: the ending state is retained for retry.
        assertEndingPhase(model.appPhase, result: result, context: context)

        // The escape hatch: the confirmed discard drops the result, writes
        // nothing, and returns to Tasks.
        model.discardEndOfSession()
        XCTAssertEqual(model.appPhase, .tasksView)
        XCTAssertFalse(model.isSessionActive)
        // Nothing was written — the obstruction is untouched.
        XCTAssertEqual(try Data(contentsOf: logsPath), obstruction)
    }

    func testDiscardOutsideEndingPhaseIsTypedNoOp() async throws {
        let model = await makeConfiguredModel()
        model.discardEndOfSession()
        XCTAssertEqual(model.appPhase, .tasksView, "untouched outside .endingSession")
    }

    // MARK: - Completion failure after a successful log (typed partial outcome)

    func testCompletionFailureAfterLogIsTypedPartialOutcome() async throws {
        let taskID = UUID()
        try writeTaskFile("Partial task", id: taskID, status: .toDo, in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, _) = try await runSessionToEnd(on: model, taskID: taskID)

        // Inject the completion failure: change the task file's bytes on
        // disk after load — the #7 reload-before-write staleness guard
        // refuses the completion write with `.vaultChangedExternally`.
        let taskFile = vaultURL.appendingPathComponent("Tasks", isDirectory: true)
            .appendingPathComponent("Partial task.md")
        var text = try String(contentsOf: taskFile, encoding: .utf8)
        text += "\nExternal edit while the session was running.\n"
        try text.write(to: taskFile, atomically: true, encoding: .utf8)

        let outcome = try await model.submitEndOfSession(makeForm(completed: .yes))

        // The typed partial outcome, exact case.
        XCTAssertEqual(
            outcome,
            .completionFailedAfterLog(
                .vaultChangedExternally(id: taskID, fileName: "Partial task.md")))
        // The ending state is cleared; issue #23 routes the flow's exit to
        // the post-session choice carrying the failure for the inline #22
        // warning.
        XCTAssertEqual(
            model.appPhase,
            .postSessionChoice(
                completionFailure: .vaultChangedExternally(
                    id: taskID, fileName: "Partial task.md")))
        XCTAssertFalse(model.isSessionActive)

        // The session IS logged (log-first ordering held).
        let logged = try await parseBackSession(result)
        XCTAssertEqual(logged.sessionID, result.sessionID)
        XCTAssertEqual(logged.taskCompleted, true, "the log records the Yes answer")

        // The status is NOT updated on disk — still the In-Progress status
        // the session start wrote (the completion was refused), never Done.
        // The user completes the task manually in the UI.
        let onDisk = try await parseBackTask(id: taskID)
        XCTAssertEqual(onDisk.status, .inProgress, "the completion write was refused")
    }

    // MARK: - Submission-required enforcement (issue criterion 5, §12.5)

    func testStartsAreRefusedWithSessionEndingUnresolvedWhileEnding() async throws {
        let taskID = UUID()
        let otherID = UUID()
        try writeTaskFile("Ending guard task", id: taskID, in: vaultURL)
        try writeTaskFile("Second task", id: otherID, in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, context) = try await runSessionToEnd(on: model, taskID: taskID)

        let regular = try await model.startSession(taskID: otherID)
        XCTAssertEqual(regular, .refused(.sessionEndingUnresolved))
        let adHoc = try await model.startAdHocSession(
            title: "Ad hoc while ending", categoryNames: ["Testing"])
        XCTAssertEqual(adHoc, .refused(.sessionEndingUnresolved))

        // Nothing started; the ending phase is untouched.
        XCTAssertFalse(model.isSessionActive)
        XCTAssertEqual(model.sessionState, .idle)
        assertEndingPhase(model.appPhase, result: result, context: context)
        let tasksOnDisk = try await VaultStore(vaultURL: vaultURL).load()
        guard case .loaded(let inventory) = tasksOnDisk else {
            XCTFail("expected a loaded vault")
            return
        }
        // The fixture ships 3 tasks; the two written above make 5 — the
        // refusals created no ad-hoc file and changed no status.
        XCTAssertEqual(inventory.tasks.count, 5, "no ad-hoc task was created")
        XCTAssertEqual(
            inventory.tasks.first { $0.id == otherID }?.status, .toDo,
            "the second task's status is untouched")
    }

    func testSetVaultPathIsRefusedWhileEnding() async throws {
        let taskID = UUID()
        try writeTaskFile("Vault guard task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, context) = try await runSessionToEnd(on: model, taskID: taskID)

        let neverCreated = root.appendingPathComponent("never-created-vault")
        let outcome = await model.setVaultPath(to: neverCreated)

        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        // The stores/settings are untouched — the pending result must log
        // into the vault the session ran against (§18).
        XCTAssertEqual(model.vaultURL, vaultURL)
        XCTAssertEqual(
            settings.vaultPath, vaultURL.path(percentEncoded: false))
        assertEndingPhase(model.appPhase, result: result, context: context)
    }

    // MARK: - notes-empty → nil in the file (issue criterion 16)

    func testEmptyNotesComposeAsNilInTheFile() async throws {
        let taskID = UUID()
        try writeTaskFile("Notes nil task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let (result, _) = try await runSessionToEnd(on: model, taskID: taskID)

        let outcome = try await model.submitEndOfSession(
            makeForm(completed: .no, notes: "   "))

        XCTAssertEqual(outcome, .success)
        let logged = try await parseBackSession(result)
        XCTAssertNil(logged.notes, "trimmed-empty notes are nil in the file")
    }

    // MARK: - Day selection (issue criterion 10: pure helper, END day)

    func testLogDayIsTheLocalCalendarDayOfEndedAt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        let startedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 23, minute: 30)))
        let endedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 0, minute: 15)))

        // Sanity: the START day would name the 4th file.
        XCTAssertEqual(
            DailyLogDay.fileName(for: startedAt, calendar: calendar), "2026-09-04.md")
        // The END day pins the destination: a midnight-spanning session
        // logs to the day it ENDED on.
        XCTAssertEqual(
            DailyLogDay.fileName(
                for: AppModel.logDay(forEndedAt: endedAt, calendar: calendar),
                calendar: calendar),
            "2026-09-05.md")

        // A same-day session keeps its day (no off-by-one).
        let sameDay = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 9, minute: 0)))
        XCTAssertEqual(
            DailyLogDay.fileName(
                for: AppModel.logDay(forEndedAt: sameDay, calendar: calendar),
                calendar: calendar),
            "2026-09-04.md")
    }
}
