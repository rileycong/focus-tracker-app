import XCTest
@testable import FocusTracker

/// Integration tests for the #9 `VaultStore` status-transition wrappers.
/// Every test copies `fixtures/sample-vault/` into a fresh temp directory —
/// the repo fixture is never touched (same convention as the #6/#7/#8 tests).
/// After each wrapper operation the affected parent file on disk re-parses
/// through `FrontmatterCodec` to a tree equal to the in-memory post-write
/// state (parse-back equality, PRD §18 valid Markdown/YAML).
final class VaultStoreTransitionTests: XCTestCase {

    // MARK: - Fixture access

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private static let planQ4ID = UUID(uuidString: "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02")!
    private static let collectInputID = UUID(uuidString: "8a4c2e6f-1d3b-4f5a-8b9c-2e7d1a4c6e08")!
    private static let draftOKRID = UUID(uuidString: "5d9e7f2a-3c6b-4a1d-9e8f-6b2c4d7a9e13")!
    private static let defineObjectivesID = UUID(
        uuidString: "1b6d8f3a-4e7c-4b2a-8d5e-9f3b1c6d8e24")!
    private static let mapKeyResultsID = UUID(
        uuidString: "7c3e9a4b-5f8d-4c3b-9e6f-1a4c2d8e9f35")!
    private static let readDeepWorkID = UUID(uuidString: "c9d1e3f5-2a4b-4c6d-8e0f-7b9a1d3c5e69")!
    private static let renewPassportID = UUID(uuidString: "a2b8c4d6-9e1f-4a7b-b3c5-8d2e6f4a1c47")!

    private var root: URL!
    private var vaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "VaultStoreTransitionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private struct ExpectedLoadedFailure: Error {}

    private func requireLoaded(
        _ state: VaultStore.LoadState, file: StaticString = #filePath, line: UInt = #line
    ) throws -> VaultStore.Inventory {
        guard case .loaded(let inventory) = state else {
            XCTFail("expected .loaded(...), got \(state)", file: file, line: line)
            throw ExpectedLoadedFailure()
        }
        return inventory
    }

    private func makeStore(for vault: URL? = nil) -> VaultStore {
        VaultStore(vaultURL: vault ?? vaultURL)
    }

    private var tasksDirectory: URL {
        vaultURL.appendingPathComponent("Tasks", isDirectory: true)
    }

    private func taskFile(_ name: String) -> URL {
        tasksDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private var planFile: URL { taskFile("Plan Q4 roadmap.md") }

    private func bytes(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func makeTask(
        id: UUID = UUID(), title: String, status: TaskStatus = .toDo
    ) throws -> TaskItem {
        try TaskItem(
            id: id, title: title, categories: [Category(name: "Testing")], status: status)
    }

    /// Asserts the awaited operation throws exactly `expected` (exact-case).
    private func expectStoreError<T>(
        _ expected: VaultStoreError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as VaultStoreError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    /// Parse-back equality (PRD §18): the named file's bytes re-parse through
    /// the codec to a tree exactly equal to `expected`, and the store's
    /// in-memory copy of that task agrees — disk and inventory match with no
    /// reload needed after a successful write.
    private func assertParseBackEqual(
        _ expected: TaskItem,
        fileName: String,
        store: VaultStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let fileText = try String(decoding: bytes(at: taskFile(fileName)), as: UTF8.self)
        let (frontmatter, _) = try FrontmatterCodec.split(fileText)
        let parsed = try FrontmatterCodec.decodeTask(frontmatter: frontmatter)
        XCTAssertEqual(parsed, expected, "file must re-parse to the post-write tree",
                       file: file, line: line)

        guard case .task(let inMemory) = await store.lookup(expected.id) else {
            return XCTFail("task \(expected.id) missing from inventory", file: file, line: line)
        }
        XCTAssertEqual(inMemory, expected, "inventory must match disk after the write",
                       file: file, line: line)
    }

    /// Loads the current on-disk tasks with a fresh store.
    private func diskTasks(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [TaskItem] {
        let fresh = makeStore()
        let inventory = try requireLoaded(await fresh.load(), file: file, line: line)
        return inventory.tasks
    }

    /// The tree (owning parent task, or the task itself) an ID resolves to —
    /// hoisted out of XCTest autoclosures, which do not support `await`.
    private func unwrapOwningTask(
        _ id: UUID, from store: VaultStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> TaskItem {
        let result = await store.lookup(id)
        return try XCTUnwrap(
            result.extractTask(), "no owning task for \(id.uuidString)",
            file: file, line: line)
    }

    /// Replaces the fixture's "Renew passport.md" with different valid content
    /// (same ID) — the external edit the staleness guard must catch.
    private func externallyRewriteRenewPassport() throws {
        let fileText = """
        ---
        id: \(Self.renewPassportID.uuidString)
        title: Renew passport
        status: Blocked
        categories:
          - Admin
        notes: Externally edited while the store held a stale copy.
        ---

        External bytes.
        """
        try fileText.write(to: taskFile("Renew passport.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - startSession

    func testStartSessionMovesToDoTaskToInProgressWithParseBackEquality() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let task = try makeTask(title: "Write weekly review")
        _ = try await store.create(task)

        let outcome = try await store.startSession(task.id)

        XCTAssertEqual(outcome, .transitioned([task.id]))
        var expected = task
        expected.status = .inProgress
        try await assertParseBackEqual(expected, fileName: "Write weekly review.md", store: store)
    }

    func testStartSessionOnInProgressTaskIsNoOpWritingNothing() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let before = try bytes(at: planFile)

        let outcome = try await store.startSession(Self.planQ4ID)

        XCTAssertEqual(outcome, .transitioned([]))
        XCTAssertEqual(try bytes(at: planFile), before, "no-op must not touch the file")
    }

    func testStartSessionRefusalsWriteNothing() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let planBefore = try bytes(at: planFile)
        let passportBefore = try bytes(at: taskFile("Renew passport.md"))
        let deepWorkBefore = try bytes(at: taskFile("Read Deep Work.md"))

        // Blocked → manual unblock first:
        let blocked = try await store.startSession(Self.renewPassportID)
        XCTAssertEqual(blocked, .refused(.blocked))
        // Dropped → manual restore only:
        let dropped = try await store.startSession(Self.readDeepWorkID)
        XCTAssertEqual(dropped, .refused(.dropped))
        // Done → nothing to work on (a Done subtask of Plan Q4):
        let done = try await store.startSession(Self.collectInputID)
        XCTAssertEqual(done, .refused(.alreadyDone))

        XCTAssertEqual(try bytes(at: taskFile("Renew passport.md")), passportBefore)
        XCTAssertEqual(try bytes(at: taskFile("Read Deep Work.md")), deepWorkBefore)
        XCTAssertEqual(try bytes(at: planFile), planBefore)
    }

    func testStartSessionOnSubtaskRewritesOnlyTheParentFile() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let deepWorkBefore = try bytes(at: taskFile("Read Deep Work.md"))
        let passportBefore = try bytes(at: taskFile("Renew passport.md"))
        var expected = try await unwrapOwningTask(Self.mapKeyResultsID, from: store)

        let outcome = try await store.startSession(Self.mapKeyResultsID)

        XCTAssertEqual(outcome, .transitioned([Self.mapKeyResultsID]))
        expected = expected.applying(status: .inProgress, to: [Self.mapKeyResultsID])
        try await assertParseBackEqual(
            expected, fileName: "Plan Q4 roadmap.md", store: store)
        XCTAssertEqual(try bytes(at: taskFile("Read Deep Work.md")), deepWorkBefore)
        XCTAssertEqual(try bytes(at: taskFile("Renew passport.md")), passportBefore)
    }

    // MARK: - complete

    func testCompleteWithoutBubbleUpChangesOnlyTheTargetSubtask() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        // "Map key results" has a Blocked sibling ("Define Q4 objectives"),
        // so completing it must NOT complete "Draft OKRs" or the task.
        var expected = try await unwrapOwningTask(Self.mapKeyResultsID, from: store)

        let outcome = try await store.complete(Self.mapKeyResultsID)

        XCTAssertEqual(outcome, .transitioned([Self.mapKeyResultsID]))
        expected = expected.applying(status: .done, to: [Self.mapKeyResultsID])
        try await assertParseBackEqual(expected, fileName: "Plan Q4 roadmap.md", store: store)
        XCTAssertEqual(expected.status, .inProgress)
        XCTAssertEqual(
            try XCTUnwrap(expected.subtaskTree(Self.draftOKRID)).status, .inProgress)
    }

    func testCompleteBubbleUpRewritesOneFileWithAllStatusesUpdated() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let deepWorkBefore = try bytes(at: taskFile("Read Deep Work.md"))
        let passportBefore = try bytes(at: taskFile("Renew passport.md"))

        // Mixed siblings hold the parent open: complete the To Do leaf, then
        // release the Blocked sibling (the explicit unblock path), then
        // complete it — the whole chain flips in one derived set.
        let leafOutcome = try await store.complete(Self.mapKeyResultsID)
        XCTAssertEqual(leafOutcome, .transitioned([Self.mapKeyResultsID]))
        let unblockOutcome = try await store.unblock(Self.defineObjectivesID)
        XCTAssertEqual(unblockOutcome, .transitioned([Self.defineObjectivesID]))
        let bubbleOutcome = try await store.complete(Self.defineObjectivesID)
        XCTAssertEqual(
            bubbleOutcome,
            .transitioned([Self.defineObjectivesID, Self.draftOKRID, Self.planQ4ID]))

        // The ONE affected top-level file holds every updated status at once
        // (one atomic rewrite, not one write per changed ID):
        let tasks = await store.tasks
        let plan = try XCTUnwrap(tasks.first { $0.id == Self.planQ4ID })
        XCTAssertEqual(plan.status, .done)
        XCTAssertEqual(
            try XCTUnwrap(plan.subtaskTree(Self.collectInputID)).status, .done)
        XCTAssertEqual(try XCTUnwrap(plan.subtaskTree(Self.draftOKRID)).status, .done)
        XCTAssertEqual(
            try XCTUnwrap(plan.subtaskTree(Self.defineObjectivesID)).status, .done)
        XCTAssertEqual(
            try XCTUnwrap(plan.subtaskTree(Self.mapKeyResultsID)).status, .done)
        try await assertParseBackEqual(plan, fileName: "Plan Q4 roadmap.md", store: store)

        // No other file was touched:
        XCTAssertEqual(try bytes(at: taskFile("Read Deep Work.md")), deepWorkBefore)
        XCTAssertEqual(try bytes(at: taskFile("Renew passport.md")), passportBefore)
    }

    func testCompleteAlreadyDoneTargetIsAnEmptyNoOp() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let before = try bytes(at: planFile)

        let outcome = try await store.complete(Self.collectInputID)

        XCTAssertEqual(outcome, .transitioned([]))
        XCTAssertEqual(try bytes(at: planFile), before, "no-op must not touch the file")
    }

    // MARK: - unblock / drop / restore

    func testUnblockThenStartSessionRoundTripOnBlockedTask() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        let unblocked = try await store.unblock(Self.renewPassportID)
        XCTAssertEqual(unblocked, .transitioned([Self.renewPassportID]))
        var expected = try await unwrapOwningTask(Self.renewPassportID, from: store)
        XCTAssertEqual(expected.status, .toDo)
        try await assertParseBackEqual(
            expected, fileName: "Renew passport.md", store: store)

        let started = try await store.startSession(Self.renewPassportID)
        XCTAssertEqual(started, .transitioned([Self.renewPassportID]))
        expected.status = .inProgress
        try await assertParseBackEqual(
            expected, fileName: "Renew passport.md", store: store)
    }

    func testDropFromEachActiveStatusThenRestoreLandsOnToDo() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let statuses: [TaskStatus] = [.toDo, .inProgress, .blocked]
        var tasks: [TaskItem] = []
        for (index, status) in statuses.enumerated() {
            let task = try makeTask(title: "Droppable \(index)", status: status)
            _ = try await store.create(task)
            tasks.append(task)
        }

        for (index, task) in tasks.enumerated() {
            let fileName = "Droppable \(index).md"
            let dropped = try await store.drop(task.id)
            XCTAssertEqual(dropped, .transitioned([task.id]))
            var expected = task
            expected.status = .dropped
            try await assertParseBackEqual(expected, fileName: fileName, store: store)

            // restore: Dropped → To Do, never directly In Progress.
            let restored = try await store.restore(task.id)
            XCTAssertEqual(restored, .transitioned([task.id]))
            expected.status = .toDo
            try await assertParseBackEqual(expected, fileName: fileName, store: store)
            let onDisk = try await diskTasks()
            XCTAssertEqual(
                try XCTUnwrap(onDisk.first { $0.id == task.id }).status, .toDo)
        }
    }

    func testDropAndRestoreRefusalsAndNoOpsWriteNothing() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let planBefore = try bytes(at: planFile)
        let passportBefore = try bytes(at: taskFile("Renew passport.md"))
        let deepWorkBefore = try bytes(at: taskFile("Read Deep Work.md"))

        // Dropping Done work is refused (nothing to abandon):
        // "Collect team input" is a Done subtask inside Plan Q4.
        let dropDone = try await store.drop(Self.collectInputID)
        XCTAssertEqual(dropDone, .refused(.alreadyDone))
        XCTAssertEqual(try bytes(at: planFile), planBefore)

        // Dropping an already-Dropped task is an idempotent no-op:
        let dropDropped = try await store.drop(Self.readDeepWorkID)
        XCTAssertEqual(dropDropped, .transitioned([]))
        XCTAssertEqual(try bytes(at: taskFile("Read Deep Work.md")), deepWorkBefore)

        // Restoring a task that is not Dropped is a no-op:
        let restoreBlocked = try await store.restore(Self.renewPassportID)
        XCTAssertEqual(restoreBlocked, .transitioned([]))
        XCTAssertEqual(try bytes(at: taskFile("Renew passport.md")), passportBefore)
    }

    func testRestoreDroppedTaskToToDoOnDisk() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        let restored = try await store.restore(Self.readDeepWorkID)
        XCTAssertEqual(restored, .transitioned([Self.readDeepWorkID]))
        let expected = try await unwrapOwningTask(Self.readDeepWorkID, from: store)
        XCTAssertEqual(expected.status, .toDo)
        XCTAssertNotEqual(expected.status, .inProgress)
        try await assertParseBackEqual(
            expected, fileName: "Read Deep Work.md", store: store)
        let onDisk = try await diskTasks()
        XCTAssertEqual(
            try XCTUnwrap(onDisk.first { $0.id == Self.readDeepWorkID }).status, .toDo)
    }

    // MARK: - Ad-hoc In-Progress start (PRD §8.6)

    func testAdHocTaskCreatedInProgressPersistsAndStartsAsNoOp() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        // §8.6 decision (documented on StatusTransition): the caller
        // constructs the ad-hoc task with .inProgress and creates it via the
        // existing #7 create — the status persists through the codec.
        let adHoc = try makeTask(title: "Ad-hoc from the timer", status: .inProgress)
        _ = try await store.create(adHoc)
        try await assertParseBackEqual(adHoc, fileName: "Ad-hoc from the timer.md", store: store)

        // The first session proceeds with nothing changing (pinned no-op):
        let outcome = try await store.startSession(adHoc.id)
        XCTAssertEqual(outcome, .transitioned([]))
        try await assertParseBackEqual(adHoc, fileName: "Ad-hoc from the timer.md", store: store)
    }

    // MARK: - Error propagation (existing typed errors, unchanged)

    func testUnknownIDsSurfaceUnknownTaskIDFromEveryWrapper() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let unknown = UUID()

        try await expectStoreError(.unknownTaskID(unknown)) { try await store.startSession(unknown) }
        try await expectStoreError(.unknownTaskID(unknown)) { try await store.complete(unknown) }
        try await expectStoreError(.unknownTaskID(unknown)) { try await store.unblock(unknown) }
        try await expectStoreError(.unknownTaskID(unknown)) { try await store.drop(unknown) }
        try await expectStoreError(.unknownTaskID(unknown)) { try await store.restore(unknown) }
    }

    func testStalenessConflictPropagatesWritesNothingAndReloadRetrySucceeds() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        try externallyRewriteRenewPassport()
        let externalBytes = try bytes(at: taskFile("Renew passport.md"))

        try await expectStoreError(
            .vaultChangedExternally(id: Self.renewPassportID, fileName: "Renew passport.md")
        ) {
            try await store.unblock(Self.renewPassportID)
        }
        XCTAssertEqual(
            try bytes(at: taskFile("Renew passport.md")), externalBytes,
            "nothing may be written on a staleness conflict")

        // Recovery path: load() then retry.
        _ = try requireLoaded(await store.load())
        let retried = try await store.unblock(Self.renewPassportID)
        XCTAssertEqual(retried, .transitioned([Self.renewPassportID]))
        let expected = try await unwrapOwningTask(Self.renewPassportID, from: store)
        XCTAssertEqual(expected.status, .toDo)
        try await assertParseBackEqual(
            expected, fileName: "Renew passport.md", store: store)
    }

    func testUnavailableVaultSurfacesWriteFailedDirectoryMissing() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let task = try makeTask(title: "Vanishing vault task")
        _ = try await store.create(task)
        try FileManager.default.removeItem(at: tasksDirectory)

        try await expectStoreError(
            .writeFailed(.directoryMissing(path: tasksDirectory.path(percentEncoded: false)))
        ) {
            try await store.startSession(task.id)
        }
    }

    // MARK: - Issue #32 regression pins (the reported flow, real fixture tree)

    /// The #32 report, pinned against the real fixture tree: completing ONE
    /// subtask while a sibling is not Done must NOT complete the parent (the
    /// whole tree must not vanish), and completing the LAST subtask must
    /// complete the parent in the same single-file change set.
    func testSubtaskCompletionSiblingsHoldParentThenLastOneCompletesIt()
        async throws
    {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        // Step 1 — "Map key results" has a Blocked sibling ("Define Q4
        // objectives"): only the target completes; "Draft OKRs" and the
        // "Plan Q4 roadmap" task stay active.
        let firstOutcome = try await store.complete(Self.mapKeyResultsID)
        XCTAssertEqual(firstOutcome, .transitioned([Self.mapKeyResultsID]))
        let heldOpen = try await unwrapOwningTask(Self.mapKeyResultsID, from: store)
        XCTAssertEqual(heldOpen.status, .inProgress, "parent NOT completed")
        XCTAssertEqual(
            heldOpen.subtaskTree(Self.draftOKRID)?.status, .inProgress,
            "the target's parent subtask NOT completed")
        try await assertParseBackEqual(
            heldOpen.applying(status: .done, to: [Self.mapKeyResultsID]),
            fileName: "Plan Q4 roadmap.md", store: store)

        // Step 2 — the last subtask of "Draft OKRs" ("Define Q4 objectives",
        // unblocked first): completing it bubbles to "Draft OKRs" AND the
        // top-level task in ONE derived change set.
        _ = try await store.unblock(Self.defineObjectivesID)
        let lastOutcome = try await store.complete(Self.defineObjectivesID)
        XCTAssertEqual(
            lastOutcome,
            .transitioned([Self.defineObjectivesID, Self.draftOKRID, Self.planQ4ID]))
        let completed = try await unwrapOwningTask(Self.planQ4ID, from: store)
        XCTAssertEqual(completed.status, .done)
        try await assertParseBackEqual(
            completed, fileName: "Plan Q4 roadmap.md", store: store)
    }
}

// MARK: - Small test-side tree accessors

private extension VaultStore.LookupResult {
    /// The looked-up task itself (top-level) or the parent task owning a
    /// subtask — the tree a transition decision and write apply to.
    func extractTask() -> TaskItem? {
        switch self {
        case .task(let task):
            return task
        case .subtask(_, let parent):
            return parent
        case .notFound:
            return nil
        }
    }
}

private extension TaskItem {
    /// The subtask with `id` anywhere in this task's recursive tree.
    func subtaskTree(_ id: UUID) -> SubtaskItem? {
        if let chain = SubtaskItem.chain(to: id, in: subtasks) {
            return chain.last
        }
        return nil
    }
}
