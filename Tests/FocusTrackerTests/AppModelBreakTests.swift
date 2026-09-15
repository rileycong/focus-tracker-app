import XCTest
import AppKit
@testable import FocusTracker

// File-local aliases keep the #23 nested-type assertions readable.
private typealias SessionContext = AppModel.SessionContext

/// Tests for the #23 `AppModel` break flow (issue #23): the post-submission
/// choice routing (after `.success` AND `.completionFailedAfterLog`, never
/// after `.logAppendFailed`), Start Next Session → `.sessionStart (#34)` with nothing
/// logged, the break lifecycle through the model (custom duration, expiry →
/// observable expired state → path back), the END-day `appendBreak`
/// parse-back with consistent fields, the end-early actual duration, the
/// typed refusal extensions (`.breakActive`, `.postSessionChoiceActive`,
/// `setVaultPath` while a break runs), and the non-blocking break-log
/// failure. Temp-dir fixture copy per the established pattern; the FakeClock
/// drives every duration so the append arithmetic invariant holds exactly.
@MainActor
final class AppModelBreakTests: XCTestCase {

    // MARK: - Test doubles (same seams as the #22 tests)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(by interval: TimeInterval) {
            monotonicSeconds += interval
            wallClockNow = wallClockNow.addingTimeInterval(interval)
        }
    }

    private final class ManualTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
    }

    private final class FocusProbe { var isActive = true }
    private final class BeepCounter { var count = 0 }

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
            .appendingPathComponent("AppModelBreakTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "AppModelBreakTests-\(UUID().uuidString)"
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

    private struct TestFailure: Error {}

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

    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let probe = focusProbe!
        let counter = beeps!
        let alarm = ExpiryAlarmController(
            beep: { counter.count += 1 }, isAppActive: { probe.isActive })
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

    private func makeForm() -> EndOfSessionFormState {
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 4
        form.energyRating = 3
        return form
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

    /// The pinned 10/5/15 telemetry (the append invariant holds exactly).
    private func runPinnedTelemetry(on model: AppModel) throws {
        clock.advance(by: 600)
        try model.pauseSession()
        clock.advance(by: 300)
        try model.resumeSession()
        clock.advance(by: 900)
    }

    /// Drives one full session through the #22 modal to the #23 choice
    /// phase via the `.success` path.
    @discardableResult
    private func runSessionToChoice(
        on model: AppModel, taskID: UUID, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> FocusSessionResult {
        _ = try await startRunningSession(on: model, taskID: taskID)
        try runPinnedTelemetry(on: model)
        let result = try model.endSession()
        let submission = try await model.submitEndOfSession(makeForm())
        guard submission == .success else {
            XCTFail("expected .success, got \(String(describing: submission))",
                    file: file, line: line)
            throw TestFailure()
        }
        XCTAssertEqual(
            model.appPhase, .postSessionChoice(completionFailure: nil),
            file: file, line: line)
        return result
    }

    /// The logged break parsed back from the END-day file on disk (a fresh
    /// store — the parse-back the issue pins).
    private func parseBackBreak(
        _ log: BreakLog, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> BreakLog {
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(for: AppModel.logDay(forEndedAt: log.endedAt))
        return try XCTUnwrap(
            day.breaks.first { $0.breakID == log.breakID },
            "break present in the end-day file", file: file, line: line)
    }

    /// Replaces `Logs/` with a regular FILE so any append fails typed with
    /// `.directoryCreationFailed` (nothing written) — the #22 obstruction.
    private func obstructLogsDirectory() throws -> URL {
        let logsDirectory = vaultURL.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.removeItem(at: logsDirectory)
        let logsPath = vaultURL.appendingPathComponent("Logs", isDirectory: false)
        try Data("not a directory".utf8).write(to: logsPath)
        return logsPath
    }

    // MARK: - Choice after .success; Start Next Session (criteria 1 + 4)

    func testStartNextSessionOpensSessionStartAndLogsNothing() async throws {
        let taskID = UUID()
        try writeTaskFile("Choice task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let result = try await runSessionToChoice(on: model, taskID: taskID)

        // PINNED: Start Next Session → .sessionStart (#34), nothing auto-opens and
        // nothing auto-starts.
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertFalse(model.isSessionActive, "no session auto-started")
        XCTAssertFalse(model.isBreakActive, "no break auto-begun")

        // Nothing was logged by the choice: the day file carries exactly the
        // session the submission wrote — no break entry.
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(for: AppModel.logDay(forEndedAt: result.endedAt))
        XCTAssertEqual(day.sessions.count, 1)
        XCTAssertEqual(day.breaks, [])
    }

    func testBackToTasksAfterSuccessRoutesWithoutWrites() async throws {
        let taskID = UUID()
        try writeTaskFile("Back success task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        let result = try await runSessionToChoice(on: model, taskID: taskID)
        let logURL = vaultURL.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(DailyLogDay.fileName(for: result.endedAt))
        let before = try Data(contentsOf: logURL)

        model.chooseBackToTasks()

        XCTAssertEqual(model.appPhase, .tasksView)
        XCTAssertFalse(model.isSessionActive)
        XCTAssertFalse(model.isBreakActive)
        XCTAssertEqual(try Data(contentsOf: logURL), before, "navigation performs no write")
    }

    // MARK: - Choice after the partial outcome, NOT after log failure
    // (criteria 1 + 3)

    func testChoiceAppearsAfterCompletionFailureButNotAfterLogAppendFailure()
        async throws
    {
        let retryTaskID = UUID()
        try writeTaskFile("Choice retry task", id: retryTaskID, in: vaultURL)
        let partialTaskID = UUID()
        try writeTaskFile("Choice partial task", id: partialTaskID, status: .toDo, in: vaultURL)
        let model = await makeConfiguredModel()

        // Path A: the log append fails → the modal stays up (retry), NO
        // choice. Obstruct Logs/ first.
        let context = try await startRunningSession(on: model, taskID: retryTaskID)
        try runPinnedTelemetry(on: model)
        let result = try model.endSession()
        let logsPath = try obstructLogsDirectory()
        let failed = try await model.submitEndOfSession(makeForm())
        guard case .logAppendFailed = failed else {
            XCTFail("expected .logAppendFailed, got \(String(describing: failed))")
            return
        }
        if case .postSessionChoice = model.appPhase {
            XCTFail("the choice must NOT appear after .logAppendFailed")
        }
        // The ending state is retained for retry (the modal stays up).
        assertEndingPhase(model.appPhase, result: result, context: context)
        try FileManager.default.removeItem(at: logsPath)

        // Retry succeeds → the choice appears.
        let retried = try await model.submitEndOfSession(makeForm())
        XCTAssertEqual(retried, .success)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))

        // Path B: the completion fails after a successful log → the choice
        // appears CARRYING the partial-outcome failure for the inline #22
        // warning (criterion 3).
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .sessionStart)
        _ = try await startRunningSession(on: model, taskID: partialTaskID)
        try runPinnedTelemetry(on: model)
        _ = try model.endSession()
        // Inject the #7 staleness refusal for the completion write.
        let taskFile = vaultURL.appendingPathComponent("Tasks", isDirectory: true)
            .appendingPathComponent("Choice partial task.md")
        var text = try String(contentsOf: taskFile, encoding: .utf8)
        text += "\nExternal edit while the session was running.\n"
        try text.write(to: taskFile, atomically: true, encoding: .utf8)

        var yesForm = EndOfSessionFormState()
        yesForm.completedChoice = .yes
        yesForm.focusRating = 4
        yesForm.energyRating = 3
        let partial = try await model.submitEndOfSession(yesForm)
        XCTAssertEqual(
            partial,
            .completionFailedAfterLog(
                .vaultChangedExternally(id: partialTaskID, fileName: "Choice partial task.md")))
        XCTAssertEqual(
            model.appPhase,
            .postSessionChoice(
                completionFailure: .vaultChangedExternally(
                    id: partialTaskID, fileName: "Choice partial task.md")),
            "the partial path stops at the choice with the warning payload")

        let logURL = vaultURL.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(DailyLogDay.fileName(for: clock.wallClockNow))
        let beforeBack = try Data(contentsOf: logURL)
        model.chooseBackToTasks()
        XCTAssertEqual(model.appPhase, .tasksView)
        XCTAssertEqual(
            try Data(contentsOf: logURL), beforeBack,
            "Back to Tasks after completionFailedAfterLog performs no extra write")
    }

    // MARK: - Break lifecycle: custom duration → expiry → path back
    // (criteria 5, 15, 16, 17)

    func testTakeBreakCustomDurationExpiryThenPathBackLogsBreakToEndDay()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Break flow task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runSessionToChoice(on: model, taskID: taskID)

        // Take Break with a CUSTOM duration (2 minutes, not the default).
        try model.takeBreak(duration: 120)
        XCTAssertEqual(model.appPhase, .breakActive)
        XCTAssertTrue(model.isBreakActive)
        XCTAssertEqual(model.breakDurationSeconds, 120)

        // Mid-countdown derived values through the model passthroughs.
        clock.advance(by: 70)
        XCTAssertEqual(model.breakRemainingSeconds, 50)
        XCTAssertEqual(model.breakProgressFraction, 70.0 / 120.0, accuracy: 1e-12)
        XCTAssertFalse(model.isBreakExpired)

        // Expiry: the observable expired/notification state flips true —
        // and the break screen stays up (no auto-dismiss, no auto-start).
        clock.advance(by: 60)  // 130 s total, past the 120 s duration
        XCTAssertTrue(model.isBreakExpired)
        XCTAssertEqual(model.breakRemainingSeconds, 0)
        XCTAssertEqual(model.appPhase, .breakActive, "no auto-dismiss")

        // The path back: the break ends and logs at the acknowledgment.
        let outcome = await model.endBreak()
        guard case .logged(let logged) = outcome else {
            XCTFail("expected .logged(...), got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertFalse(model.isBreakActive)
        XCTAssertNil(model.pendingBreakLogWarning)

        // Parse-back: the BreakLog is in the END-day file, consistent —
        // clamped to the configured duration with invariant timestamps.
        let parsed = try await parseBackBreak(logged)
        XCTAssertEqual(parsed.breakID, logged.breakID)
        XCTAssertEqual(parsed.startedAt, logged.startedAt)
        XCTAssertEqual(parsed.endedAt, logged.endedAt)
        XCTAssertEqual(parsed.duration, 2, "clamped to the configured 2 minutes")
        XCTAssertEqual(
            parsed.endedAt.timeIntervalSince(parsed.startedAt), 120, accuracy: 1e-9,
            "ended_at − started_at == duration exactly (the #11 invariant)")
    }

    func testFocusedBreakExpiryKeepsBannerPathWithoutAlarm() async throws {
        let taskID = UUID()
        try writeTaskFile("Focused break task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runSessionToChoice(on: model, taskID: taskID)
        try model.takeBreak(duration: 60)
        focusProbe.isActive = true

        clock.advance(by: 60)
        model.evaluateBreakExpiry()

        XCTAssertTrue(model.isBreakExpired)
        XCTAssertTrue(model.isBreakActive, "focused expiry keeps the in-app banner path")
        XCTAssertEqual(model.appPhase, .breakActive)
        XCTAssertFalse(model.isExpiryAlarmActive)
        XCTAssertEqual(beeps.count, 0)
    }

    func testUnfocusedBreakExpiryAlarmsThenFocusBackLogsExpiryAndRoutes() async throws {
        let taskID = UUID()
        try writeTaskFile("Alarm break task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runSessionToChoice(on: model, taskID: taskID)
        try model.takeBreak(duration: 120)
        focusProbe.isActive = false

        clock.advance(by: 130)
        model.evaluateBreakExpiry()
        XCTAssertTrue(model.isExpiryAlarmActive)
        XCTAssertEqual(beeps.count, 1, "the shared controller beeps immediately")
        XCTAssertEqual(model.appPhase, .breakActive)

        clock.advance(by: 90)
        focusProbe.isActive = true
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where model.isBreakActive {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.isExpiryAlarmActive)
        XCTAssertFalse(model.isBreakActive)
        XCTAssertEqual(model.appPhase, .sessionStart)
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(for: clock.wallClockNow)
        let logged = try XCTUnwrap(day.breaks.last)
        XCTAssertEqual(logged.duration, 2)
        XCTAssertEqual(
            logged.endedAt.timeIntervalSince(logged.startedAt), 120, accuracy: 1e-9,
            "focus-back delay is excluded; ended_at is the expiry instant")
    }

    // MARK: - End break early (criterion 14: the actual shorter duration)

    func testEndBreakEarlyLogsActualShorterDuration() async throws {
        let taskID = UUID()
        try writeTaskFile("Early end task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runSessionToChoice(on: model, taskID: taskID)

        try model.takeBreak(duration: BreakTimerEngine.defaultDurationSeconds)
        clock.advance(by: 130)

        let outcome = await model.endBreak()
        guard case .logged(let logged) = outcome else {
            XCTFail("expected .logged(...), got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(model.appPhase, .sessionStart)

        // The ACTUAL shorter duration is what lands in the file: 130 s →
        // nearest minute 2, with the reconciled invariant span.
        XCTAssertEqual(logged.duration, 2)
        let parsed = try await parseBackBreak(logged)
        XCTAssertEqual(parsed.duration, 2)
        XCTAssertEqual(
            parsed.endedAt.timeIntervalSince(parsed.startedAt), 120, accuracy: 1e-9)
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(for: AppModel.logDay(forEndedAt: logged.endedAt))
        XCTAssertEqual(day.sessions.count, 1, "the session is unaffected")
        XCTAssertEqual(day.breaks.map(\.breakID), [logged.breakID])
    }

    // MARK: - Refusals while the break is active (criteria 19 + 21)

    func testStartsRefusedWithNewTypedCaseWhileBreakActive() async throws {
        let taskID = UUID()
        let otherID = UUID()
        try writeTaskFile("Break guard task", id: taskID, in: vaultURL)
        try writeTaskFile("Second task", id: otherID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runSessionToChoice(on: model, taskID: taskID)
        try model.takeBreak(duration: 300)

        let regular = try await model.startSession(taskID: otherID)
        XCTAssertEqual(regular, .refused(.breakActive))
        let adHoc = try await model.startAdHocSession(
            title: "Ad hoc during break", categoryNames: ["Testing"])
        XCTAssertEqual(adHoc, .refused(.breakActive))

        // Nothing started, the break and its phase untouched.
        XCTAssertFalse(model.isSessionActive)
        XCTAssertTrue(model.isBreakActive)
        XCTAssertEqual(model.appPhase, .breakActive)
        // The refusal created no ad-hoc file and changed no status (the
        // fixture ships 3 tasks; the two written above make 5).
        let inventory = try await VaultStore(vaultURL: vaultURL).load()
        guard case .loaded(let loaded) = inventory else {
            XCTFail("expected a loaded vault")
            return
        }
        XCTAssertEqual(loaded.tasks.count, 5, "no ad-hoc task was created")
        XCTAssertEqual(
            loaded.tasks.first { $0.id == otherID }?.status, .toDo,
            "the second task's status is untouched")
    }

    func testSetVaultPathRefusedWhileBreakActive() async throws {
        let taskID = UUID()
        try writeTaskFile("Vault break guard task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runSessionToChoice(on: model, taskID: taskID)
        try model.takeBreak(duration: 300)

        let neverCreated = root.appendingPathComponent("never-created-vault")
        let outcome = await model.setVaultPath(to: neverCreated)

        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        // The stores/settings are untouched — the pending break will
        // appendBreak through the CURRENT stores (§18).
        XCTAssertEqual(model.vaultURL, vaultURL)
        XCTAssertEqual(settings.vaultPath, vaultURL.path(percentEncoded: false))
        XCTAssertEqual(model.appPhase, .breakActive)
    }

    // MARK: - Refusals while the choice phase is up (criterion 20 + 21)

    func testStartsRefusedWhileChoiceButVaultPathIsNot() async throws {
        let taskID = UUID()
        let otherID = UUID()
        try writeTaskFile("Choice guard task", id: taskID, in: vaultURL)
        try writeTaskFile("Choice other task", id: otherID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runSessionToChoice(on: model, taskID: taskID)

        let regular = try await model.startSession(taskID: otherID)
        XCTAssertEqual(regular, .refused(.postSessionChoiceActive))
        let adHoc = try await model.startAdHocSession(
            title: "Ad hoc during choice", categoryNames: ["Testing"])
        XCTAssertEqual(adHoc, .refused(.postSessionChoiceActive))
        XCTAssertFalse(model.isSessionActive)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))

        // Criterion 21: the choice phase does NOT refuse the vault path —
        // nothing is pending a write until the break actually starts.
        let otherVault = root.appendingPathComponent("choice-phase-vault")
        let pathOutcome = await model.setVaultPath(to: otherVault)
        XCTAssertEqual(pathOutcome, .changed)
    }

    // MARK: - Break log failure: typed, non-blocking (criterion 18)

    func testBreakLogFailureIsTypedNonBlockingAndStillReachesSessionStart()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Break log failure task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        _ = try await runSessionToChoice(on: model, taskID: taskID)
        try model.takeBreak(duration: 300)
        clock.advance(by: 300)

        let logsPath = try obstructLogsDirectory()
        let outcome = await model.endBreak()

        guard case .logFailed(let log, let error) = outcome else {
            XCTFail("expected .logFailed(...), got \(String(describing: outcome))")
            return
        }
        // The composed log itself was well-formed (clamped to the
        // configured duration) — only the write was obstructed.
        XCTAssertEqual(log.duration, 5)
        guard case .directoryCreationFailed(let path, _) = error else {
            XCTFail("expected .directoryCreationFailed, got \(error)")
            return
        }
        XCTAssertEqual(
            path,
            vaultURL.appendingPathComponent("Logs", isDirectory: true)
                .path(percentEncoded: false))
        // NON-BLOCKING by pinned design: the flow still reaches .sessionStart (#34),
        // the break is over, and the small warning is surfaced.
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertFalse(model.isBreakActive)
        XCTAssertEqual(model.pendingBreakLogWarning, error.description)
        // Nothing was written — the obstruction is untouched.
        XCTAssertEqual(try Data(contentsOf: logsPath), Data("not a directory".utf8))
    }

    // MARK: - Day selection (criterion 23: pure, END day)

    func testLogDayForABreakEndingAfterMidnightIsItsEndDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        let startedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 23, minute: 50)))
        let endedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 0, minute: 5)))

        // Sanity: the START day would name the 4th file.
        XCTAssertEqual(DailyLogDay.fileName(for: startedAt, calendar: calendar), "2026-09-04.md")
        // The END day pins the destination: a break spanning midnight logs
        // to the day it ENDED on (the reused #22 helper, unchanged).
        XCTAssertEqual(
            DailyLogDay.fileName(
                for: AppModel.logDay(forEndedAt: endedAt, calendar: calendar),
                calendar: calendar),
            "2026-09-05.md")
    }
}
