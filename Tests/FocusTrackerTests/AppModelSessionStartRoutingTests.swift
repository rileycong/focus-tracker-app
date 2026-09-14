import XCTest
@testable import FocusTracker

// File-local aliases keep the phase/refusal assertions readable.
private typealias AppPhase = AppModel.AppPhase
private typealias SessionStartRefusal = AppModel.SessionStartRefusal

/// Tests for the #34 direct-to-session-start routing and last-session
/// pre-selection on `AppModel` (issue #34, amending #23's pinned exit
/// routing): the post-modal Start Next Session choice opens the
/// `.sessionStart` phase (was: `.tasksView`); both break ends (the expiry
/// acknowledgment and the early end, including the non-blocking log-failure
/// path) land there too; a successful start records the session's target
/// in-memory (`lastSessionTargetID` — surviving end/submit/cancel/discard,
/// overwritten by the next start, never present on a fresh model: the
/// user's "has not quit the application" scoping); starting FROM the new
/// phase works (it IS the start surface — no refusal case) while the
/// #19/#22/#23 refusal chain stays intact around it; Cancel returns to
/// Tasks keeping the tracking; and the manual entry point composes the
/// same pre-selection (row hand-off winning over the last target), with a
/// Done previous task clearing the effective pre-selection while the
/// tracking itself stays. Temp-dir fixture copy per the established
/// pattern; the FakeClock drives every duration.
@MainActor
final class AppModelSessionStartRoutingTests: XCTestCase {

    // MARK: - Test doubles (same seams as the #22/#23/#33 tests)

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
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
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

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "SessionStartRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "SessionStartRoutingTests-\(UUID().uuidString)"
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

    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let model = AppModel(
            settings: settings, persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(), sessionClock: clock)
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

    private func startSession(
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

    private func makeForm() -> EndOfSessionFormState {
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 4
        form.energyRating = 3
        return form
    }

    /// Drives one full session (10 focused minutes, No completion) through
    /// the #22 modal to the #23 choice phase and through Start Next Session
    /// to the #34 `.sessionStart` phase.
    @discardableResult
    private func runSessionToSessionStart(
        on model: AppModel, taskID: UUID, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> UUID {
        _ = try await startSession(on: model, taskID: taskID, file: file, line: line)
        clock.advance(by: 600)
        let result = try model.endSession()
        XCTAssertEqual(model.lastSessionTargetID, taskID, "tracking set at start")
        let submission = try await model.submitEndOfSession(makeForm())
        XCTAssertEqual(submission, .success, file: file, line: line)
        XCTAssertEqual(
            model.appPhase, .postSessionChoice(completionFailure: nil),
            file: file, line: line)
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .sessionStart, file: file, line: line)
        return result.taskID
    }

    // MARK: - In-memory scoping (criterion: a fresh AppModel has none)

    func testFreshModelHasNoLastTargetTracking() async {
        // Unconfigured fresh model.
        let bare = AppModel(settings: settings)
        XCTAssertNil(bare.lastSessionTargetID, "no session has started yet")

        // Configured + bootstrapped fresh model (still no start in-process).
        let model = await makeConfiguredModel()
        XCTAssertNil(
            model.lastSessionTargetID,
            "in-memory only: a fresh model (a relaunch) starts with none")
    }

    // MARK: - Post-modal Start Next Session → .sessionStart (criterion 1)

    func testStartNextSessionOpensSessionStartPhaseWithPreselectionSet()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Routing choice task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()

        try await runSessionToSessionStart(on: model, taskID: taskID)

        // The phase IS the session-start menu; the pre-selection is set;
        // nothing auto-starts (no session, no break).
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertEqual(model.lastSessionTargetID, taskID)
        XCTAssertFalse(model.isSessionActive, "nothing auto-starts")
        XCTAssertFalse(model.isBreakActive, "no break auto-begins")
        // The picker composition (what the shell hands the sheet) resolves
        // to the tracked target — the pre-selection is visible and Start is
        // one click away.
        XCTAssertEqual(
            SessionStartPicker.preselectedTargetID(
                requesting: model.lastSessionTargetID, in: model.tasks),
            taskID)
    }

    func testStartingFromSessionStartPhaseWorksAndRetargetsTracking()
        async throws
    {
        let firstID = UUID()
        let secondID = UUID()
        try writeTaskFile("Routing first task", id: firstID, in: vaultURL)
        try writeTaskFile("Routing second task", id: secondID, in: vaultURL)
        let model = await makeConfiguredModel()
        try await runSessionToSessionStart(on: model, taskID: firstID)

        // Starts are NOT refused in `.sessionStart` — it IS the start
        // surface (#34): the sheet's Start runs the ordinary #19 flow.
        let context = try await startSession(on: model, taskID: secondID)
        XCTAssertEqual(model.appPhase, .timerView(context))
        XCTAssertEqual(model.lastSessionTargetID, secondID, "re-recorded")
    }

    func testCancelFromSessionStartReturnsToTasksAndKeepsTracking()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Routing cancel task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        try await runSessionToSessionStart(on: model, taskID: taskID)

        model.cancelSessionStart()
        XCTAssertEqual(model.appPhase, .tasksView)
        XCTAssertEqual(
            model.lastSessionTargetID, taskID,
            "canceling the menu is not ending the loop — tracking kept")

        // Typed no-op outside `.sessionStart`: the phase stays on Tasks.
        model.cancelSessionStart()
        XCTAssertEqual(model.appPhase, .tasksView)
    }

    // MARK: - Break ends → .sessionStart (criterion 2)

    func testBreakExpiryAcknowledgmentLandsOnSessionStartWithPreselection()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Routing break task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        try await runSessionToSessionStart(on: model, taskID: taskID)

        try model.takeBreak(duration: 120)
        XCTAssertEqual(model.appPhase, .breakActive)
        clock.advance(by: 130)
        XCTAssertTrue(model.isBreakExpired, "the expiry state is observable")

        // The post-expiry acknowledgment path (the same endBreak API).
        let outcome = await model.endBreak()
        guard case .logged = outcome else {
            XCTFail("expected .logged(...), got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(
            model.appPhase, .sessionStart,
            "the break end goes directly to the session-start sheet (#34)")
        XCTAssertEqual(model.lastSessionTargetID, taskID)
        XCTAssertFalse(model.isBreakActive)
    }

    func testBreakEarlyEndLandsOnSessionStartWithPreselection()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Routing early end task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        try await runSessionToSessionStart(on: model, taskID: taskID)

        try model.takeBreak(duration: 300)
        clock.advance(by: 130)

        let outcome = await model.endBreak()
        guard case .logged = outcome else {
            XCTFail("expected .logged(...), got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertEqual(model.lastSessionTargetID, taskID)
    }

    func testBreakLogFailureStillLandsOnSessionStart()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Routing break failure task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        try await runSessionToSessionStart(on: model, taskID: taskID)
        try model.takeBreak(duration: 300)
        clock.advance(by: 130)

        // Replace Logs/ with a regular file: every append fails typed.
        let logsDirectory = vaultURL.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.removeItem(at: logsDirectory)
        try Data("not a directory".utf8).write(
            to: vaultURL.appendingPathComponent("Logs", isDirectory: false))

        let outcome = await model.endBreak()
        guard case .logFailed = outcome else {
            XCTFail("expected .logFailed(...), got \(String(describing: outcome))")
            return
        }
        // NON-BLOCKING by pinned design — and the #34 routing holds on the
        // failure path too: the flow still reaches the session-start sheet.
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertEqual(model.lastSessionTargetID, taskID)
        XCTAssertNotNil(model.pendingBreakLogWarning)
    }

    // MARK: - Tracking lifecycle (criterion 3: survives, overwritten, dies)

    func testTrackingSurvivesEndSubmitCancelAndAdHocRetargets() async throws {
        let taskID = UUID()
        try writeTaskFile("Routing survive task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()

        _ = try await startSession(on: model, taskID: taskID)
        XCTAssertEqual(model.lastSessionTargetID, taskID)

        // End (the confirm step) keeps the tracking...
        _ = try model.endSession()
        XCTAssertEqual(model.lastSessionTargetID, taskID)
        // ...Cancel (#29) restores the session and keeps it...
        XCTAssertEqual(try model.cancelEndOfSession(), .restored)
        XCTAssertEqual(model.lastSessionTargetID, taskID)
        // ...the second end + the #27 discard keeps it...
        _ = try model.endSession()
        model.discardEndOfSession()
        XCTAssertEqual(model.appPhase, .tasksView)
        XCTAssertEqual(model.lastSessionTargetID, taskID)
        // ...and the third lifecycle's end + submission keeps it too (the
        // tracking records the START, not the lifecycle).
        _ = try await startSession(on: model, taskID: taskID)
        _ = try model.endSession()
        let submission = try await model.submitEndOfSession(makeForm())
        XCTAssertEqual(submission, .success)
        XCTAssertEqual(model.lastSessionTargetID, taskID)

        // Resolve the choice, then an ad-hoc start re-records the tracking
        // to the created task (starts are allowed in `.sessionStart`).
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .sessionStart)
        let adHoc = try await model.startAdHocSession(
            title: "Routing ad hoc", categoryNames: ["Testing"])
        guard case .started = adHoc else {
            XCTFail("expected .started(...), got \(adHoc)")
            return
        }
        let recorded = try XCTUnwrap(model.lastSessionTargetID)
        XCTAssertNotEqual(recorded, taskID)
        XCTAssertTrue(
            model.tasks.contains { $0.id == recorded },
            "the ad-hoc task is the new tracked target")
    }

    // MARK: - Manual entry point + eligibility (criterion 3)

    func testManualEntryPointComposesLastTargetPreselection() async throws {
        let taskID = UUID()
        let rowID = UUID()
        try writeTaskFile("Routing manual task", id: taskID, in: vaultURL)
        try writeTaskFile("Routing row task", id: rowID, in: vaultURL)
        let model = await makeConfiguredModel()
        try await startSession(on: model, taskID: taskID)
        _ = try model.endSession()
        model.discardEndOfSession()
        XCTAssertEqual(model.appPhase, .tasksView)

        // The toolbar entry passes no row hand-off; TasksView composes
        // `request.preselectedTargetID ?? model.lastSessionTargetID`.
        let manualRequestID: UUID? = nil
        let composed = manualRequestID ?? model.lastSessionTargetID
        XCTAssertEqual(
            SessionStartPicker.preselectedTargetID(requesting: composed, in: model.tasks),
            taskID, "the manual entry point pre-selects the last session's target")

        // A row hand-off (the context-menu entry) wins over the last target.
        let rowComposed = rowID ?? model.lastSessionTargetID
        XCTAssertEqual(
            SessionStartPicker.preselectedTargetID(requesting: rowComposed, in: model.tasks),
            rowID)
    }

    func testDonePreviousTaskClearsEffectivePreselectionKeepsTracking()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Routing done task", id: taskID, in: vaultURL)
        let model = await makeConfiguredModel()
        try await startSession(on: model, taskID: taskID)
        clock.advance(by: 600)
        _ = try model.endSession()
        _ = try await model.submitEndOfSession(makeForm())
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .sessionStart)

        // The previous task turns Done on disk; the inventory refreshes.
        try writeTaskFile("Routing done task", id: taskID, status: .done, in: vaultURL)
        await model.reloadVault()

        // The tracking itself is unchanged (an honest "what did I last work
        // on"); the EFFECTIVE pre-selection clears — the picker starts
        // unselected.
        XCTAssertEqual(model.lastSessionTargetID, taskID)
        XCTAssertNil(
            SessionStartPicker.preselectedTargetID(
                requesting: model.lastSessionTargetID, in: model.tasks),
            "Done previous task → no pre-selection")
    }

    // MARK: - Refusal chain intact around the new phase (criterion: #33/#19)

    func testRefusalChainStaysIntactAroundTheNewPhase() async throws {
        let taskID = UUID()
        let otherID = UUID()
        try writeTaskFile("Routing guard task", id: taskID, in: vaultURL)
        try writeTaskFile("Routing other task", id: otherID, in: vaultURL)
        let model = await makeConfiguredModel()

        // While `.endingSession` is up: the #22 refusal.
        _ = try await startSession(on: model, taskID: taskID)
        clock.advance(by: 600)
        _ = try model.endSession()
        var attempt = try await model.startSession(taskID: otherID)
        XCTAssertEqual(attempt, .refused(.sessionEndingUnresolved))

        // While `.postSessionChoice` is up: the #23 refusal.
        _ = try await model.submitEndOfSession(makeForm())
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))
        attempt = try await model.startSession(taskID: otherID)
        XCTAssertEqual(attempt, .refused(.postSessionChoiceActive))

        // While `.breakActive` is up: the #23 break refusal.
        try model.takeBreak(duration: 300)
        attempt = try await model.startSession(taskID: otherID)
        XCTAssertEqual(attempt, .refused(.breakActive))

        // After the break ends (now: `.sessionStart`), the start SUCCEEDS —
        // the phase is the start surface.
        clock.advance(by: 130)
        _ = await model.endBreak()
        XCTAssertEqual(model.appPhase, .sessionStart)
        attempt = try await model.startSession(taskID: otherID)
        XCTAssertEqual(
            attempt,
            .started(
                AppModel.SessionContext(
                    taskID: otherID, title: "Routing other task",
                    parentTaskTitle: nil, project: nil,
                    categories: [Category(name: "Testing")])))
    }
}
