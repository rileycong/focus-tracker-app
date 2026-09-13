import XCTest
@testable import FocusTracker

// The #19 outcome/context types are nested in `AppModel`; file-local aliases
// keep the assertions readable.
private typealias SessionStartOutcome = AppModel.SessionStartOutcome
private typealias SessionContext = AppModel.SessionContext

/// Tests for the #19 `AppModel` session-start orchestration (issue #19):
/// the pinned refusal order with exact typed cases, the success path with
/// disk parse-back + snapshot persistence, the In-Progress no-op path, the
/// §8.6 ad-hoc creation path, duration handling, and deep subtask targeting
/// (the owning file transitions). Temp-dir fixture copy per the established
/// pattern; the FakeClock starts at monotonic 0 so `remainingSeconds`
/// asserts are exact.
@MainActor
final class AppModelSessionStartTests: XCTestCase {

    // MARK: - Test doubles (same seams as the #13/#14 tests)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
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
            .appendingPathComponent("SessionStartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "SessionStartTests-\(UUID().uuidString)"
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
        let model = AppModel(
            settings: settings, persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(), sessionClock: clock)
        await model.bootstrap()
        return model
    }

    private func requireStarted(
        _ outcome: SessionStartOutcome, file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SessionContext {
        guard case .started(let context) = outcome else {
            XCTFail("expected .started(...), got \(outcome)", file: file, line: line)
            throw TestFailure()
        }
        return context
    }

    private struct TestFailure: Error {}

    /// The vault's on-disk state, parsed back through a fresh store (the
    /// "disk parse-back" the issue pins — never the model's in-memory copy).
    private func parseBackTasks() async throws -> [TaskItem] {
        let store = VaultStore(vaultURL: vaultURL)
        guard case .loaded(let inventory) = await store.load() else {
            XCTFail("expected a loaded vault on parse-back")
            throw TestFailure()
        }
        return inventory.tasks
    }

    private func parseBackTask(
        id: UUID, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> TaskItem {
        let tasks = try await parseBackTasks()
        return try XCTUnwrap(tasks.first { $0.id == id }, "task on disk", file: file, line: line)
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

    private func requireNoEngineStart(
        _ model: AppModel, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertFalse(
            model.isSessionActive, "no engine start", file: file, line: line)
        XCTAssertEqual(model.sessionState, .idle, file: file, line: line)
        let snapshot = try FileActiveSessionPersistence(directory: persistenceDirectory)
            .load()
        XCTAssertNil(snapshot, "no snapshot persisted", file: file, line: line)
        XCTAssertEqual(
            model.appPhase, .tasksView, "phase untouched", file: file, line: line)
    }

    /// The fixture's one In-Progress task ("Plan Q4 roadmap", filename-sorted
    /// first) and To Do lookup helpers over the loaded model.
    private func fixtureTask(
        titled title: String, in model: AppModel
    ) throws -> TaskItem {
        try XCTUnwrap(model.tasks.first { $0.title == title })
    }

    // MARK: - Success path (To Do → In Progress, engine running, snapshot persisted)

    func testStartSessionOnToDoTaskTransitionsDiskAndStartsEngine() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID, status: .toDo, in: vaultURL)
        let model = await makeConfiguredModel()

        let context = try requireStarted(
            try await model.startSession(taskID: taskID))

        // The typed context carries the resolved display fields.
        XCTAssertEqual(context.taskID, taskID)
        XCTAssertEqual(context.title, "Alpha task")
        XCTAssertNil(context.parentTaskTitle)
        XCTAssertEqual(context.categories.map(\.name), ["Testing"])

        // Disk parse-back: the whole file was written through to In Progress.
        let onDisk = try await parseBackTask(id: taskID)
        XCTAssertEqual(onDisk.status, .inProgress)

        // Engine running + initial snapshot persisted in the injected dir.
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertTrue(model.isSessionActive)
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: persistenceDirectory, includingPropertiesForKeys: nil)
        XCTAssertFalse(directoryContents.isEmpty, "snapshot file exists")
        let snapshot = try FileActiveSessionPersistence(directory: persistenceDirectory)
            .load()
        XCTAssertEqual(snapshot?.taskID, taskID)

        // App phase swapped to the timer with the context.
        XCTAssertEqual(model.appPhase, .timerView(context))

        // Default duration honored (PRD §9.2: 25 min), clock at 0.
        XCTAssertEqual(model.remainingSeconds, 1500)
    }

    func testStartSessionOnSubtaskCarriesParentContext() async throws {
        let parentID = UUID()
        let subtaskID = UUID()
        try writeTaskFile(
            "Parent task", id: parentID, status: .toDo,
            subtasks: [SubtaskItem(id: subtaskID, title: "The subtask")], in: vaultURL)
        let model = await makeConfiguredModel()

        let context = try requireStarted(
            try await model.startSession(taskID: subtaskID))

        XCTAssertEqual(context.taskID, subtaskID)
        XCTAssertEqual(context.title, "The subtask")
        XCTAssertEqual(context.parentTaskTitle, "Parent task")
    }

    // MARK: - In-Progress no-op path

    func testStartSessionOnInProgressTaskIsAllowedNoOp() async throws {
        let model = await makeConfiguredModel()
        let inProgress = try fixtureTask(titled: "Plan Q4 roadmap", in: model)
        let filePath = vaultURL
            .appendingPathComponent("Tasks", isDirectory: true)
            .appendingPathComponent("Plan Q4 roadmap.md")
        let bytesBefore = try Data(contentsOf: filePath)

        let context = try requireStarted(
            try await model.startSession(taskID: inProgress.id))

        // No status write needed: the file is byte-identical (the empty
        // change set is a legitimate no-op, #9).
        XCTAssertEqual(try Data(contentsOf: filePath), bytesBefore)
        let onDisk = try await parseBackTask(id: inProgress.id)
        XCTAssertEqual(onDisk.status, .inProgress)
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertTrue(model.isSessionActive)
        XCTAssertEqual(model.appPhase, .timerView(context))
    }

    // MARK: - Refusal paths (exact typed cases; nothing changes)

    func testBlockedTargetIsRefusedWithTypeCaseAndNothingChanges() async throws {
        let model = await makeConfiguredModel()
        let blocked = try fixtureTask(titled: "Renew passport", in: model)

        let outcome = try await model.startSession(taskID: blocked.id)

        XCTAssertEqual(outcome, .refused(.targetRefused(blocked.id, .blocked)))
        let onDisk = try await parseBackTask(id: blocked.id)
        XCTAssertEqual(onDisk.status, .blocked, "no status change")
        try requireNoEngineStart(model)
    }

    func testDroppedTargetIsRefusedWithTypeCaseAndNothingChanges() async throws {
        let model = await makeConfiguredModel()
        let dropped = try fixtureTask(titled: "Read Deep Work", in: model)

        let outcome = try await model.startSession(taskID: dropped.id)

        XCTAssertEqual(outcome, .refused(.targetRefused(dropped.id, .dropped)))
        let onDisk = try await parseBackTask(id: dropped.id)
        XCTAssertEqual(onDisk.status, .dropped)
        try requireNoEngineStart(model)
    }

    func testDoneTargetIsRefusedWithTypeCaseAndNothingChanges() async throws {
        let doneID = UUID()
        try writeTaskFile("Finished task", id: doneID, status: .done, in: vaultURL)
        let model = await makeConfiguredModel()

        let outcome = try await model.startSession(taskID: doneID)

        XCTAssertEqual(outcome, .refused(.targetRefused(doneID, .alreadyDone)))
        let onDisk = try await parseBackTask(id: doneID)
        XCTAssertEqual(onDisk.status, .done)
        try requireNoEngineStart(model)
    }

    func testSessionAlreadyActiveIsRefusedBeforeLaterSteps() async throws {
        let model = await makeConfiguredModel()
        let inProgress = try fixtureTask(titled: "Plan Q4 roadmap", in: model)
        let toDoID = UUID()
        try writeTaskFile("Second task", id: toDoID, status: .toDo, in: vaultURL)
        await model.reloadVault()
        _ = try requireStarted(try await model.startSession(taskID: inProgress.id))
        XCTAssertTrue(model.isSessionActive)

        // A second start — on a target that would otherwise be fine — hits
        // the FIRST pinned refusal, before lookup or the #9 transition.
        let outcome = try await model.startSession(taskID: toDoID)
        XCTAssertEqual(outcome, .refused(.sessionAlreadyActive))

        // The first session is untouched.
        XCTAssertTrue(model.isSessionActive)
        XCTAssertEqual(model.sessionState, .running)
    }

    func testVaultNotConfiguredIsRefusedWithTypeCase() async throws {
        // A model with no vault path at all (never configured).
        // An isolated, empty suite — the test intent is an unconfigured
        // model, and the runner's standard defaults may hold a real
        // vaultPath on a machine where the app has been run.
        let unconfigured = AppModel(
            settings: try AppSettings(
                suiteName: "SessionStartTests-unconfigured-\(UUID().uuidString)"),
            persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(), sessionClock: clock)
        await unconfigured.bootstrap()

        let outcome = try await unconfigured.startSession(taskID: UUID())

        XCTAssertEqual(outcome, .refused(.vaultNotConfigured))
        try requireNoEngineStart(unconfigured)
    }

    func testPendingRecoveryUnresolvedIsRefusedWithTypeCase() async throws {
        // A snapshot on disk surfaces the #14 pending state on bootstrap;
        // a start is refused until the user resolves it.
        let pendingSnapshot = ActiveSessionSnapshot(
            sessionID: UUID(), taskID: UUID(), duration: 1500,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 30, accumulatedPausedSeconds: 0,
            pauseCount: 0, isPaused: false, segmentStartMonotonic: 42)
        try FileActiveSessionPersistence(directory: persistenceDirectory)
            .save(pendingSnapshot)
        let model = await makeConfiguredModel()
        XCTAssertNotNil(model.pendingSessionRecovery)
        let toDoID = UUID()
        try writeTaskFile("Pending gate task", id: toDoID, status: .toDo, in: vaultURL)
        await model.reloadVault()

        let outcome = try await model.startSession(taskID: toDoID)

        XCTAssertEqual(outcome, .refused(.pendingRecoveryUnresolved))
        let onDisk = try await parseBackTask(id: toDoID)
        XCTAssertEqual(onDisk.status, .toDo, "no status change")
        // No engine start; the pending snapshot is untouched by the refusal
        // (unlike the other refusals, the on-disk snapshot legitimately
        // remains — it is exactly what awaits the user's resolution).
        XCTAssertFalse(model.isSessionActive)
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertEqual(model.pendingSessionRecovery, pendingSnapshot)
        XCTAssertEqual(model.appPhase, .tasksView)

        // After the user resolves the pending state, the same start succeeds.
        XCTAssertEqual(model.discardPendingSession(), .discarded)
        _ = try requireStarted(try await model.startSession(taskID: toDoID))
        let resolved = try await parseBackTask(id: toDoID)
        XCTAssertEqual(resolved.status, .inProgress)
    }

    func testUnknownTargetIsItsOwnTypedRefusal() async throws {
        let model = await makeConfiguredModel()
        let unknown = UUID()

        let outcome = try await model.startSession(taskID: unknown)

        XCTAssertEqual(outcome, .refused(.unknownTarget(unknown)))
        try requireNoEngineStart(model)
    }

    // MARK: - Ad-hoc creation path (PRD §8.6)

    func testAdHocSessionCreatesInProgressTaskOnDiskAndStartsOnIt() async throws {
        let model = await makeConfiguredModel()
        let tasksBefore = try await parseBackTasks()

        let outcome = try await model.startAdHocSession(
            title: "Ad hoc focus", categoryNames: ["work", "Work", " deep "])
        let context = try requireStarted(outcome)

        // Disk parse-back: exactly one new file, In Progress, with the #16
        // normalization applied (trim + case-insensitive dedupe).
        let tasksAfter = try await parseBackTasks()
        XCTAssertEqual(tasksAfter.count, tasksBefore.count + 1)
        let created = try XCTUnwrap(tasksAfter.first { $0.id == context.taskID })
        XCTAssertEqual(created.title, "Ad hoc focus")
        XCTAssertEqual(created.status, .inProgress)
        XCTAssertEqual(created.categories.map(\.name), ["work", "deep"])

        // The session runs on the NEW task's ID (not any pre-existing one),
        // and the engine's linked ID is the same one an eventual §13 log
        // would carry.
        XCTAssertFalse(tasksBefore.contains { $0.id == context.taskID })
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertTrue(model.isSessionActive)
        XCTAssertEqual(model.appPhase, .timerView(context))
        let result = try model.endSession()
        XCTAssertEqual(result.taskID, context.taskID)
        // End enters the #22 required ending phase.
        assertEndingPhase(model.appPhase, result: result, context: context)
    }

    func testAdHocSessionValidationRefusalsAreTyped() async throws {
        let model = await makeConfiguredModel()

        // No category (PRD §8.6: at least one required).
        var outcome = try await model.startAdHocSession(
            title: "No cats", categoryNames: [])
        XCTAssertEqual(outcome, .refused(.adHocTaskInvalid))
        // Whitespace-only category tokens collapse to none.
        outcome = try await model.startAdHocSession(
            title: "No cats", categoryNames: ["   "])
        XCTAssertEqual(outcome, .refused(.adHocTaskInvalid))
        // Whitespace-only title.
        outcome = try await model.startAdHocSession(title: "   ", categoryNames: ["Work"])
        XCTAssertEqual(outcome, .refused(.adHocTaskInvalid))

        try requireNoEngineStart(model)
        let tasks = try await parseBackTasks()
        XCTAssertEqual(tasks.count, 3, "nothing was written")
    }

    func testAdHocSessionSharesThePinnedPrerequisiteRefusals() async throws {
        // First refusal while a session is active…
        let model2 = await makeConfiguredModel()
        let inProgress = try fixtureTask(titled: "Plan Q4 roadmap", in: model2)
        _ = try requireStarted(try await model2.startSession(taskID: inProgress.id))
        var outcome = try await model2.startAdHocSession(title: "X", categoryNames: ["Y"])
        XCTAssertEqual(outcome, .refused(.sessionAlreadyActive))
        try model2.endSession()

        // …then the unconfigured and pending-recovery refusals.
        // An isolated, empty suite — the test intent is an unconfigured
        // model, and the runner's standard defaults may hold a real
        // vaultPath on a machine where the app has been run.
        let unconfigured = AppModel(
            settings: try AppSettings(
                suiteName: "SessionStartTests-unconfigured-\(UUID().uuidString)"),
            persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(), sessionClock: clock)
        await unconfigured.bootstrap()
        outcome = try await unconfigured.startAdHocSession(title: "X", categoryNames: ["Y"])
        XCTAssertEqual(outcome, .refused(.vaultNotConfigured))

        try FileActiveSessionPersistence(directory: persistenceDirectory).save(
            ActiveSessionSnapshot(
                sessionID: UUID(), taskID: UUID(), duration: 1500,
                startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                accumulatedFocusedSeconds: 0, accumulatedPausedSeconds: 0,
                pauseCount: 0, isPaused: false, segmentStartMonotonic: 0))
        let model3 = await makeConfiguredModel()
        XCTAssertNotNil(model3.pendingSessionRecovery)
        outcome = try await model3.startAdHocSession(title: "X", categoryNames: ["Y"])
        XCTAssertEqual(outcome, .refused(.pendingRecoveryUnresolved))
    }

    // MARK: - Duration (PRD §9.2: default 25, custom honored)

    func testDefaultDurationIsTwentyFiveMinutes() async throws {
        let taskID = UUID()
        try writeTaskFile("Duration default", id: taskID, status: .toDo, in: vaultURL)
        let model = await makeConfiguredModel()

        _ = try requireStarted(try await model.startSession(taskID: taskID))

        XCTAssertEqual(model.remainingSeconds, 25 * 60)
        XCTAssertFalse(model.isSessionExpired)
    }

    func testCustomDurationIsReflectedInRemainingSeconds() async throws {
        let taskID = UUID()
        try writeTaskFile("Duration custom", id: taskID, status: .toDo, in: vaultURL)
        let model = await makeConfiguredModel()

        _ = try requireStarted(
            try await model.startSession(taskID: taskID, duration: 10 * 60))

        XCTAssertEqual(model.remainingSeconds, 600)
        // And the snapshot carries the custom duration for #13 recovery.
        let snapshot = try FileActiveSessionPersistence(directory: persistenceDirectory)
            .load()
        XCTAssertEqual(snapshot?.duration, 600)
    }

    // MARK: - Subtask targeting (depth ≥ 1, owning file transitions)

    func testSessionOnDeepSubtaskTransitionsOwningFileOnly() async throws {
        let parentID = UUID()
        let siblingID = UUID()
        let childID = UUID()
        let deepID = UUID()
        try writeTaskFile(
            "Owning task", id: parentID, status: .toDo,
            subtasks: [
                SubtaskItem(id: siblingID, title: "Sibling", children: []),
                SubtaskItem(
                    id: childID, title: "Child", children: [
                        SubtaskItem(id: deepID, title: "Deep target"),
                    ]),
            ], in: vaultURL)
        let model = await makeConfiguredModel()

        // Target the depth-2 subtask.
        let context = try requireStarted(try await model.startSession(taskID: deepID))

        XCTAssertEqual(context.taskID, deepID)
        XCTAssertEqual(context.title, "Deep target")
        XCTAssertEqual(context.parentTaskTitle, "Owning task")

        // Parse-back of the ONE owning file: the deep subtask moved to
        // In Progress; the parent task, its own status, and the sibling
        // branch are untouched.
        let onDisk = try await parseBackTask(id: parentID)
        XCTAssertEqual(onDisk.status, .toDo)
        let deepOnDisk = try XCTUnwrap(
            onDisk.subtasks.first { $0.id == childID }?.children.first { $0.id == deepID })
        XCTAssertEqual(deepOnDisk.status, .inProgress)
        XCTAssertEqual(onDisk.subtasks.first { $0.id == siblingID }?.status, .toDo)

        XCTAssertEqual(model.sessionState, .running)
        let result = try model.endSession()
        XCTAssertEqual(result.taskID, deepID, "the session links to the subtask ID")
    }

    // MARK: - App phase round trip

    func testEndSessionEntersEndingPhaseAndSubmissionStopsAtPostSessionChoice()
        async throws
    {
        let taskID = UUID()
        try writeTaskFile("Phase task", id: taskID, status: .toDo, in: vaultURL)
        let model = await makeConfiguredModel()
        XCTAssertEqual(model.appPhase, .tasksView)

        let context = try requireStarted(try await model.startSession(taskID: taskID))
        XCTAssertEqual(model.appPhase, .timerView(context))

        // Confirm: the phase holds the result + context until submission.
        let result = try model.endSession()
        assertEndingPhase(model.appPhase, result: result, context: context)
        XCTAssertEqual(model.sessionState, .idle)

        // Submission (§12.5) moves the flow to the #23 post-session choice.
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 3
        form.energyRating = 3
        let outcome = try await model.submitEndOfSession(form)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))

        // The choice's Start Next Session is what returns to Tasks (nothing
        // auto-starts or auto-opens, issue #23 criterion 4).
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .tasksView)
    }
}
