import XCTest
@testable import FocusTracker

/// Path-based subtask CRUD on `VaultStore` (issue #8, PRD §5.4, §7, §18).
/// Every vault-using test copies `fixtures/sample-vault/` into a fresh temp
/// directory — the repo fixture is never touched (same convention as the #6
/// and #7 tests). The fixture's "Plan Q4 roadmap.md" carries the subtask tree
/// exercised here: task → Collect team input / Draft objectives and key
/// results → Define Q4 objectives / Map key results to objectives.
final class VaultStoreSubtaskTests: XCTestCase {

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

    private var root: URL!
    private var vaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VaultStoreSubtaskTests-\(UUID().uuidString)", isDirectory: true)
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

    private func text(at url: URL) throws -> String {
        try String(decoding: bytes(at: url), as: UTF8.self)
    }

    private func body(of url: URL) throws -> String {
        try FrontmatterCodec.split(text(at: url)).body
    }

    /// The parent file on disk, parsed through the codec — a successful parse
    /// is the whole-file-atomicity assertion (valid Markdown/YAML, PRD §18).
    private func parsedPlan(file: StaticString = #filePath, line: UInt = #line) throws -> TaskItem {
        try FrontmatterCodec.parseTask(text(at: planFile))
    }

    /// Asserts the awaited operation throws exactly `expected`.
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

    /// Loads the current on-disk tasks with a fresh store — the reference the
    /// in-memory inventory is compared against after each write operation.
    private func diskTasks(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [TaskItem] {
        let fresh = makeStore()
        let inventory = try requireLoaded(await fresh.load(), file: file, line: line)
        return inventory.tasks
    }

    /// The store's currently loaded task with `id` (unwraps for the test).
    private func loadedTask(
        _ id: UUID, from store: VaultStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> TaskItem {
        let tasks = await store.tasks
        return try XCTUnwrap(
            tasks.first { $0.id == id },
            "no loaded task with ID \(id.uuidString)", file: file, line: line)
    }

    /// Replaces the fixture's "Plan Q4 roadmap.md" with different valid content
    /// (same ID, same subtask IDs, dropped optional fields, new body) — the
    /// external edit the staleness guard must catch. Keeping the subtask IDs
    /// lets every op type be retried against the reloaded external content.
    private func externallyRewritePlanSubtasks() throws {
        let fileText = """
        ---
        id: \(Self.planQ4ID.uuidString)
        title: Plan Q4 roadmap
        status: In Progress
        categories:
          - Planning
          - Work
        project: Work
        subtasks:
          - id: \(Self.collectInputID.uuidString)
            title: Collect team input
            status: Done
          - id: \(Self.draftOKRID.uuidString)
            title: Draft objectives and key results
            status: In Progress
            subtasks:
              - id: \(Self.defineObjectivesID.uuidString)
                title: Define Q4 objectives
                status: Blocked
              - id: \(Self.mapKeyResultsID.uuidString)
                title: Map key results to objectives
                status: To Do
        ---
        Externally edited body.
        """
        try fileText.write(to: planFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Add

    func testAddSubtaskAtRootAppendsToTheTopLevelListAndPersists() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let fixture = try await loadedTask(Self.planQ4ID, from: store)
        let bodyBefore = try body(of: planFile)

        let newSubtask = SubtaskItem(title: "Review with the team", status: .inProgress)
        let returned = try await store.addSubtask(
            parentID: Self.planQ4ID, subtask: newSubtask, toParentSubtaskID: nil)

        XCTAssertEqual(returned.id, Self.planQ4ID, "the updated parent task is returned")
        XCTAssertEqual(returned.subtasks.last?.id, newSubtask.id, "appended last")
        XCTAssertEqual(returned.subtasks.last?.title, "Review with the team")
        XCTAssertEqual(returned.subtasks.last?.status, .inProgress)
        XCTAssertEqual(
            returned.subtasks.map(\.id), fixture.subtasks.map(\.id) + [newSubtask.id],
            "existing siblings keep their order")

        // The file parses back equal to the returned parent (whole-file
        // round-trip), with the load-time body re-attached byte-for-byte.
        XCTAssertEqual(try parsedPlan(), returned)
        XCTAssertEqual(try body(of: planFile), bodyBefore)

        // The inventory matches disk with no reload; the new subtask resolves.
        let inMemory = await store.tasks
        let onDisk = try await diskTasks()
        XCTAssertEqual(inMemory, onDisk)
        guard case .subtask(let found, in: let foundParent) = await store.lookup(newSubtask.id)
        else {
            return XCTFail("the added subtask must resolve by ID")
        }
        XCTAssertEqual(found.id, newSubtask.id)
        XCTAssertEqual(foundParent.id, Self.planQ4ID)

        // lastLoadState/warnings still describe the last load (documented).
        let lastState = await store.lastLoadState
        guard case .loaded(let loadedInventory)? = lastState else {
            return XCTFail("lastLoadState must still describe the last load")
        }
        XCTAssertEqual(loadedInventory.tasks.count, 3, "the load's own snapshot, not the writes")
        let warnings = await store.warnings
        XCTAssertTrue(warnings.isEmpty)
    }

    func testAddSubtaskAtDepthThreeAppendsUnderTheNestedTarget() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        let greatGrandchild = SubtaskItem(title: "Draft the objective wording", status: .toDo)
        let returned = try await store.addSubtask(
            parentID: Self.planQ4ID, subtask: greatGrandchild,
            toParentSubtaskID: Self.defineObjectivesID)

        // task → Draft OKRs → Define Q4 objectives → new great-grandchild
        // (depth 3), as the last child of the nested target.
        let parsed = try parsedPlan()
        XCTAssertEqual(parsed, returned, "the whole parent file round-trips")
        let draft = try XCTUnwrap(parsed.subtasks.first { $0.id == Self.draftOKRID })
        let define = try XCTUnwrap(draft.children.first { $0.id == Self.defineObjectivesID })
        XCTAssertEqual(define.children.count, 1)
        XCTAssertEqual(define.children.first?.id, greatGrandchild.id)
        XCTAssertEqual(define.children.first?.title, "Draft the objective wording")
        // Unrelated branches are untouched.
        XCTAssertEqual(parsed.subtasks.first { $0.id == Self.collectInputID }?.children, [])
        XCTAssertEqual(
            draft.children.first { $0.id == Self.mapKeyResultsID }?.children, [])
        XCTAssertEqual(draft.children.map(\.id),
                       [Self.defineObjectivesID, Self.mapKeyResultsID])
    }

    func testAddSubtaskRoundTripsEveryFieldAndTheModelDefaultUUID() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        let deadline = try XCTUnwrap(DeadlineDay.date(from: "2026-10-01"))
        let full = SubtaskItem(
            title: "Book the offsite venue", status: .blocked, priority: .high, effort: .m,
            deadline: deadline, notes: "Two candidates; decide by Friday.")
        XCTAssertFalse([Self.planQ4ID, Self.collectInputID, Self.draftOKRID,
                        Self.defineObjectivesID, Self.mapKeyResultsID].contains(full.id),
                       "the model default assigned a fresh UUID")

        let returned = try await store.addSubtask(parentID: Self.planQ4ID, subtask: full)

        XCTAssertEqual(returned.subtasks.last, full, "the stored child equals what was passed")
        let parsed = try parsedPlan()
        XCTAssertEqual(parsed.subtasks.last, full,
                       "every field (incl. the model-default UUID) round-trips the codec")
        // No project/categories exist on the subtask; they resolve from
        // ancestors (#3 helpers — consumed, not stored).
        XCTAssertEqual(parsed.effectiveProject(of: full.id), Project(name: "Work"))
        XCTAssertEqual(parsed.effectiveCategories(of: full.id),
                       [Category(name: "Planning"), Category(name: "Work")])
    }

    // MARK: - Update

    func testUpdateSubtaskEditsAllEditableFieldsOnAGrandchild() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let deadline = try XCTUnwrap(DeadlineDay.date(from: "2026-09-25"))

        let returned = try await store.updateSubtask(
            parentID: Self.planQ4ID, subtaskID: Self.defineObjectivesID
        ) { subtask in
            subtask.title = "Lock the Q4 objectives"
            subtask.status = .inProgress
            subtask.priority = .high
            subtask.effort = .m
            subtask.deadline = deadline
            subtask.notes = "Unblocked once leadership signs off."
            subtask.children = [SubtaskItem(title: "Injected child")]
        }

        let draft = try XCTUnwrap(returned.subtasks.first { $0.id == Self.draftOKRID })
        let define = try XCTUnwrap(draft.children.first { $0.id == Self.defineObjectivesID })
        XCTAssertEqual(define.title, "Lock the Q4 objectives")
        XCTAssertEqual(define.status, .inProgress)
        XCTAssertEqual(define.priority, .high)
        XCTAssertEqual(define.effort, .m)
        XCTAssertEqual(define.deadline, deadline)
        XCTAssertEqual(define.notes, "Unblocked once leadership signs off.")
        XCTAssertEqual(define.id, Self.defineObjectivesID,
                       "the store re-asserts the target's id after the closure")
        XCTAssertEqual(define.children, [],
                       "children edits through the closure are discarded — tree shape is "
                     + "mutated only by add/delete/reorder")
        XCTAssertEqual(returned.subtasks.map(\.id),
                       [Self.collectInputID, Self.draftOKRID],
                       "top-level siblings untouched")
        XCTAssertEqual(draft.title, "Draft objectives and key results",
                       "ancestor fields untouched")

        XCTAssertEqual(try parsedPlan(), returned, "the whole parent file round-trips")
        let updatedInMemory = await store.tasks
        let updatedOnDisk = try await diskTasks()
        XCTAssertEqual(updatedInMemory, updatedOnDisk)
        guard case .subtask(let looked, in: _) = await store.lookup(Self.defineObjectivesID)
        else {
            return XCTFail("lookup must reflect the update")
        }
        XCTAssertEqual(looked.title, "Lock the Q4 objectives")
    }

    // MARK: - Delete

    func testDeleteSubtaskRemovesAMidLevelNodeAndItsWholeSubtree() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        // Make "Map key results to objectives" (depth 2) a mid-level node by
        // giving it a depth-3 child first.
        let leaf = SubtaskItem(title: "List candidate KRIs", status: .toDo)
        _ = try await store.addSubtask(
            parentID: Self.planQ4ID, subtask: leaf, toParentSubtaskID: Self.mapKeyResultsID)

        try await store.deleteSubtask(parentID: Self.planQ4ID, subtaskID: Self.mapKeyResultsID)

        let plan = try await loadedTask(Self.planQ4ID, from: store)
        let draft = try XCTUnwrap(plan.subtasks.first { $0.id == Self.draftOKRID })
        XCTAssertEqual(draft.children.map(\.id), [Self.defineObjectivesID],
                       "the mid-level node and its whole subtree are gone; sibling survives")
        XCTAssertEqual(plan.subtasks.map(\.id),
                       [Self.collectInputID, Self.draftOKRID],
                       "other branches survive")
        XCTAssertEqual(try parsedPlan(), plan, "the whole parent file round-trips")
        guard case .notFound = await store.lookup(Self.mapKeyResultsID) else {
            return XCTFail("the deleted node's ID no longer resolves")
        }
        guard case .notFound = await store.lookup(leaf.id) else {
            return XCTFail("the removed subtree's IDs no longer resolve either")
        }
        XCTAssertEqual(plan.effectiveProject(of: Self.defineObjectivesID),
                       Project(name: "Work"),
                       "surviving nodes still inherit from ancestors")
    }

    // MARK: - Reorder

    func testReorderSubtasksPersistsListOrderIncludingGrandchildren() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        // Top-level sibling list; fixture order is [Collect, Draft].
        let topLevel = try await store.reorderSubtasks(
            parentID: Self.planQ4ID,
            siblingIDsInNewOrder: [Self.draftOKRID, Self.collectInputID])
        XCTAssertEqual(topLevel.subtasks.map(\.id),
                       [Self.draftOKRID, Self.collectInputID])
        XCTAssertEqual(try parsedPlan(), topLevel,
                       "the file's list order persists the new order")

        // Grandchildren of "Draft objectives and key results"; fixture order
        // is [Define, Map].
        let reordered = try await store.reorderSubtasks(
            parentID: Self.planQ4ID,
            parentSubtaskID: Self.draftOKRID,
            siblingIDsInNewOrder: [Self.mapKeyResultsID, Self.defineObjectivesID])
        let draft = try XCTUnwrap(reordered.subtasks.first { $0.id == Self.draftOKRID })
        XCTAssertEqual(draft.children.map(\.id),
                       [Self.mapKeyResultsID, Self.defineObjectivesID])
        XCTAssertEqual(try parsedPlan(), reordered,
                       "grandchild order persists via the file's list order too")

        let reorderedInMemory = await store.tasks
        let reorderedOnDisk = try await diskTasks()
        XCTAssertEqual(reorderedInMemory, reorderedOnDisk)
        guard case .subtask(let map, in: _) = await store.lookup(Self.mapKeyResultsID) else {
            return XCTFail("reordered nodes still resolve by ID")
        }
        XCTAssertEqual(map.status, .toDo, "reorder touches list order only, not content")
        let taskOrder = await store.tasks
        XCTAssertEqual(taskOrder.map(\.id).firstIndex(of: Self.planQ4ID), 0,
                       "the top-level task's own inventory position is unaffected")
    }

    func testReorderRejectsOrdersThatAreNotExactPermutations() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let planBytes = try bytes(at: planFile)
        let currentTopLevel = [Self.collectInputID, Self.draftOKRID]

        // Missing ID.
        await expectStoreError(.reorderNotExactPermutation(
            currentSiblings: currentTopLevel, proposedOrder: [Self.collectInputID])) {
            try await store.reorderSubtasks(
                parentID: Self.planQ4ID, siblingIDsInNewOrder: [Self.collectInputID])
        }
        // Extra ID.
        let ghost = UUID()
        await expectStoreError(.reorderNotExactPermutation(
            currentSiblings: currentTopLevel, proposedOrder: currentTopLevel + [ghost])) {
            try await store.reorderSubtasks(
                parentID: Self.planQ4ID, siblingIDsInNewOrder: currentTopLevel + [ghost])
        }
        // Duplicated ID.
        await expectStoreError(.reorderNotExactPermutation(
            currentSiblings: currentTopLevel,
            proposedOrder: [Self.collectInputID, Self.collectInputID])) {
            try await store.reorderSubtasks(
                parentID: Self.planQ4ID,
                siblingIDsInNewOrder: [Self.collectInputID, Self.collectInputID])
        }
        XCTAssertEqual(try bytes(at: planFile), planBytes, "nothing is written on rejection")
        let rejectedInMemory = await store.tasks
        let rejectedOnDisk = try await diskTasks()
        XCTAssertEqual(rejectedInMemory, rejectedOnDisk, "inventory untouched")

        // The pure core is directly unit-testable without the actor (in the
        // spirit of #3's newlyDoneIDs): a valid permutation returns a new list
        // in the requested sequence; an invalid one throws the typed error.
        let siblings = [
            SubtaskItem(id: currentTopLevel[0], title: "A"),
            SubtaskItem(id: currentTopLevel[1], title: "B"),
        ]
        let reordered = try siblings.reordered(to: [currentTopLevel[1], currentTopLevel[0]])
        XCTAssertEqual(reordered.map(\.title), ["B", "A"])
        XCTAssertEqual(siblings.map(\.title), ["A", "B"], "the receiver is never mutated")
        XCTAssertThrowsError(try siblings.reordered(to: [currentTopLevel[0]])) { error in
            XCTAssertEqual(
                error as? VaultStoreError,
                .reorderNotExactPermutation(
                    currentSiblings: currentTopLevel, proposedOrder: [currentTopLevel[0]]))
        }
    }

    // MARK: - Staleness guard (every op type + reload-retry)

    func testStalenessConflictOnEverySubtaskOpThenReloadRetrySucceeds() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let conflict = VaultStoreError.vaultChangedExternally(
            id: Self.planQ4ID, fileName: "Plan Q4 roadmap.md")

        // add
        try externallyRewritePlanSubtasks()
        var externalBytes = try bytes(at: planFile)
        let newSubtask = SubtaskItem(title: "Retry-added subtask")
        await expectStoreError(conflict) {
            try await store.addSubtask(parentID: Self.planQ4ID, subtask: newSubtask)
        }
        XCTAssertEqual(try bytes(at: planFile), externalBytes, "add: nothing written")
        var plan = try await loadedTask(Self.planQ4ID, from: store)
        XCTAssertEqual(plan.subtasks.map(\.id),
                       [Self.collectInputID, Self.draftOKRID],
                       "add: inventory untouched by the conflict")
        _ = try requireLoaded(await store.load())
        plan = try await store.addSubtask(parentID: Self.planQ4ID, subtask: newSubtask)
        XCTAssertEqual(plan.subtasks.last?.id, newSubtask.id, "add: retry succeeds")

        // update
        try externallyRewritePlanSubtasks()
        externalBytes = try bytes(at: planFile)
        await expectStoreError(conflict) {
            try await store.updateSubtask(
                parentID: Self.planQ4ID, subtaskID: Self.defineObjectivesID
            ) { $0.notes = "updated" }
        }
        XCTAssertEqual(try bytes(at: planFile), externalBytes, "update: nothing written")
        _ = try requireLoaded(await store.load())
        plan = try await store.updateSubtask(
            parentID: Self.planQ4ID, subtaskID: Self.defineObjectivesID) { $0.notes = "updated" }
        let define = try XCTUnwrap(
            plan.subtasks.first { $0.id == Self.draftOKRID }?
                .children.first { $0.id == Self.defineObjectivesID })
        XCTAssertEqual(define.notes, "updated", "update: retry succeeds")

        // reorder
        try externallyRewritePlanSubtasks()
        externalBytes = try bytes(at: planFile)
        await expectStoreError(conflict) {
            try await store.reorderSubtasks(
                parentID: Self.planQ4ID,
                parentSubtaskID: Self.draftOKRID,
                siblingIDsInNewOrder: [Self.mapKeyResultsID, Self.defineObjectivesID])
        }
        XCTAssertEqual(try bytes(at: planFile), externalBytes, "reorder: nothing written")
        _ = try requireLoaded(await store.load())
        plan = try await store.reorderSubtasks(
            parentID: Self.planQ4ID,
            parentSubtaskID: Self.draftOKRID,
            siblingIDsInNewOrder: [Self.mapKeyResultsID, Self.defineObjectivesID])
        XCTAssertEqual(
            plan.subtasks.first { $0.id == Self.draftOKRID }?.children.map(\.id),
            [Self.mapKeyResultsID, Self.defineObjectivesID],
            "reorder: retry succeeds")

        // setStatus
        try externallyRewritePlanSubtasks()
        externalBytes = try bytes(at: planFile)
        await expectStoreError(conflict) {
            try await store.setStatus(
                parentID: Self.planQ4ID, subtaskID: Self.collectInputID, to: .inProgress)
        }
        XCTAssertEqual(try bytes(at: planFile), externalBytes, "setStatus: nothing written")
        _ = try requireLoaded(await store.load())
        plan = try await store.setStatus(
            parentID: Self.planQ4ID, subtaskID: Self.collectInputID, to: .inProgress)
        XCTAssertEqual(
            plan.subtasks.first { $0.id == Self.collectInputID }?.status, .inProgress,
            "setStatus: retry succeeds")

        // delete
        try externallyRewritePlanSubtasks()
        externalBytes = try bytes(at: planFile)
        await expectStoreError(conflict) {
            try await store.deleteSubtask(
                parentID: Self.planQ4ID, subtaskID: Self.defineObjectivesID)
        }
        XCTAssertEqual(try bytes(at: planFile), externalBytes, "delete: nothing written")
        _ = try requireLoaded(await store.load())
        try await store.deleteSubtask(parentID: Self.planQ4ID, subtaskID: Self.defineObjectivesID)
        plan = try await loadedTask(Self.planQ4ID, from: store)
        XCTAssertEqual(
            plan.subtasks.first { $0.id == Self.draftOKRID }?.children.map(\.id),
            [Self.mapKeyResultsID], "delete: retry succeeds")

        XCTAssertEqual(try parsedPlan(), plan, "the final file parses back to the store's tree")
    }

    // MARK: - Typed addressing errors

    func testSubtaskOpsReportExactTypedAddressingErrors() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let ghost = UUID()
        let ghostSubtask = SubtaskItem(id: ghost, title: "Ghost")

        // Unknown parent ID → the existing .unknownTaskID (every op).
        await expectStoreError(.unknownTaskID(ghost)) {
            try await store.addSubtask(parentID: ghost, subtask: ghostSubtask)
        }
        await expectStoreError(.unknownTaskID(ghost)) {
            try await store.updateSubtask(
                parentID: ghost, subtaskID: Self.collectInputID) { _ in }
        }
        await expectStoreError(.unknownTaskID(ghost)) {
            try await store.deleteSubtask(parentID: ghost, subtaskID: Self.collectInputID)
        }
        await expectStoreError(.unknownTaskID(ghost)) {
            try await store.reorderSubtasks(parentID: ghost, siblingIDsInNewOrder: [])
        }
        await expectStoreError(.unknownTaskID(ghost)) {
            try await store.setStatus(
                parentID: ghost, subtaskID: Self.collectInputID, to: .done)
        }

        // Parent ID that belongs to a subtask → the existing .notTopLevelTask.
        await expectStoreError(.notTopLevelTask(Self.collectInputID)) {
            try await store.addSubtask(parentID: Self.collectInputID, subtask: ghostSubtask)
        }
        await expectStoreError(.notTopLevelTask(Self.collectInputID)) {
            try await store.updateSubtask(
                parentID: Self.collectInputID, subtaskID: Self.collectInputID) { _ in }
        }
        await expectStoreError(.notTopLevelTask(Self.collectInputID)) {
            try await store.deleteSubtask(
                parentID: Self.collectInputID, subtaskID: Self.collectInputID)
        }
        await expectStoreError(.notTopLevelTask(Self.collectInputID)) {
            try await store.reorderSubtasks(
                parentID: Self.collectInputID, siblingIDsInNewOrder: [])
        }
        await expectStoreError(.notTopLevelTask(Self.collectInputID)) {
            try await store.setStatus(
                parentID: Self.collectInputID, subtaskID: Self.collectInputID, to: .done)
        }

        // Unknown subtask ID at any level → the new typed case, exact: the
        // subtask ID plus the parent task ID. Covers update/delete/setStatus
        // targets, the addSubtask toParentSubtaskID target, and the
        // reorderSubtasks parentSubtaskID target.
        let ghostInPlan = VaultStoreError.unknownSubtaskID(
            subtaskID: ghost, parentTaskID: Self.planQ4ID)
        await expectStoreError(ghostInPlan) {
            try await store.updateSubtask(parentID: Self.planQ4ID, subtaskID: ghost) { _ in }
        }
        await expectStoreError(ghostInPlan) {
            try await store.deleteSubtask(parentID: Self.planQ4ID, subtaskID: ghost)
        }
        await expectStoreError(ghostInPlan) {
            try await store.setStatus(parentID: Self.planQ4ID, subtaskID: ghost, to: .done)
        }
        await expectStoreError(ghostInPlan) {
            try await store.addSubtask(
                parentID: Self.planQ4ID, subtask: ghostSubtask, toParentSubtaskID: ghost)
        }
        await expectStoreError(ghostInPlan) {
            try await store.reorderSubtasks(
                parentID: Self.planQ4ID, parentSubtaskID: ghost, siblingIDsInNewOrder: [])
        }

        // The task's own ID is not a subtask address either.
        await expectStoreError(.unknownSubtaskID(
            subtaskID: Self.planQ4ID, parentTaskID: Self.planQ4ID)) {
            try await store.updateSubtask(
                parentID: Self.planQ4ID, subtaskID: Self.planQ4ID) { _ in }
        }

        let plan = try await loadedTask(Self.planQ4ID, from: store)
        XCTAssertEqual(plan.subtasks.map(\.id),
                       [Self.collectInputID, Self.draftOKRID], "nothing changed")
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 3)
    }

    // MARK: - Missing vault / Tasks directory

    func testSubtaskOpsSurfaceDirectoryMissingWhenVaultOrTasksMissing() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let newSubtask = SubtaskItem(title: "Never written")

        try FileManager.default.removeItem(at: vaultURL)
        let tasksPath = tasksDirectory.path(percentEncoded: false)
        let missing = VaultStoreError.writeFailed(.directoryMissing(path: tasksPath))

        await expectStoreError(missing) {
            try await store.addSubtask(parentID: Self.planQ4ID, subtask: newSubtask)
        }
        await expectStoreError(missing) {
            try await store.updateSubtask(
                parentID: Self.planQ4ID, subtaskID: Self.collectInputID) { _ in }
        }
        await expectStoreError(missing) {
            try await store.deleteSubtask(parentID: Self.planQ4ID, subtaskID: Self.collectInputID)
        }
        await expectStoreError(missing) {
            try await store.reorderSubtasks(
                parentID: Self.planQ4ID,
                siblingIDsInNewOrder: [Self.collectInputID, Self.draftOKRID])
        }
        await expectStoreError(missing) {
            try await store.setStatus(
                parentID: Self.planQ4ID, subtaskID: Self.collectInputID, to: .done)
        }

        // Vault present, Tasks/ missing: the same typed writer error.
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        await expectStoreError(missing) {
            try await store.addSubtask(parentID: Self.planQ4ID, subtask: newSubtask)
        }
        await expectStoreError(missing) {
            try await store.setStatus(
                parentID: Self.planQ4ID, subtaskID: Self.collectInputID, to: .done)
        }
    }

    // MARK: - Inheritance after ops

    func testInheritanceStillResolvesAfterEveryOperation() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let project = Project(name: "Work")
        let categories = [Category(name: "Planning"), Category(name: "Work")]

        // Added nodes (root and depth 3) inherit from the parent task.
        let addedRoot = SubtaskItem(title: "Added at root")
        let addedDeep = SubtaskItem(title: "Added deep")
        var plan = try await store.addSubtask(parentID: Self.planQ4ID, subtask: addedRoot)
        plan = try await store.addSubtask(
            parentID: Self.planQ4ID, subtask: addedDeep, toParentSubtaskID: Self.mapKeyResultsID)
        XCTAssertEqual(plan.effectiveProject(of: addedRoot.id), project)
        XCTAssertEqual(plan.effectiveCategories(of: addedRoot.id), categories)
        XCTAssertEqual(plan.effectiveProject(of: addedDeep.id), project)
        XCTAssertEqual(plan.effectiveCategories(of: addedDeep.id), categories)

        // Updated node keeps its inherited project/categories.
        plan = try await store.updateSubtask(
            parentID: Self.planQ4ID, subtaskID: Self.defineObjectivesID) { $0.status = .done }
        XCTAssertEqual(plan.effectiveProject(of: Self.defineObjectivesID), project)
        XCTAssertEqual(plan.effectiveCategories(of: Self.defineObjectivesID), categories)

        // Reordered node keeps its inherited project/categories.
        plan = try await store.reorderSubtasks(
            parentID: Self.planQ4ID,
            parentSubtaskID: Self.draftOKRID,
            siblingIDsInNewOrder: [Self.mapKeyResultsID, Self.defineObjectivesID])
        XCTAssertEqual(plan.effectiveProject(of: Self.mapKeyResultsID), project)
        XCTAssertEqual(plan.effectiveCategories(of: Self.mapKeyResultsID), categories)

        // Survivors (and their subtrees) keep inheritance after a delete.
        plan = try await loadedTask(Self.planQ4ID, from: store)
        try await store.deleteSubtask(parentID: Self.planQ4ID, subtaskID: Self.collectInputID)
        plan = try await loadedTask(Self.planQ4ID, from: store)
        XCTAssertEqual(plan.effectiveProject(of: addedDeep.id), project)
        XCTAssertEqual(plan.effectiveCategories(of: addedDeep.id), categories)
        XCTAssertEqual(plan.effectiveProject(of: Self.mapKeyResultsID), project)

        // The parsed file agrees with the in-memory resolution.
        let parsed = try parsedPlan()
        XCTAssertEqual(parsed.effectiveCategories(of: addedDeep.id), categories)
        XCTAssertEqual(parsed.effectiveProject(of: Self.defineObjectivesID), project)
    }

    // MARK: - ID collisions on add

    func testAddSubtaskFailsLoudlyOnIDCollisionsAnywhereInTheParentFile() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let planBytes = try bytes(at: planFile)

        // Collision with the task's own ID.
        await expectStoreError(.duplicateSubtaskIDOnAdd(
            subtaskID: Self.planQ4ID, parentTaskID: Self.planQ4ID)) {
            try await store.addSubtask(
                parentID: Self.planQ4ID,
                subtask: SubtaskItem(id: Self.planQ4ID, title: "Clone of the task"))
        }
        // Collision with a subtask ID in a different branch than the target.
        await expectStoreError(.duplicateSubtaskIDOnAdd(
            subtaskID: Self.collectInputID, parentTaskID: Self.planQ4ID)) {
            try await store.addSubtask(
                parentID: Self.planQ4ID,
                subtask: SubtaskItem(id: Self.collectInputID, title: "Clone"),
                toParentSubtaskID: Self.defineObjectivesID)
        }
        // Collision at the root append too (against a deeper subtask's ID).
        await expectStoreError(.duplicateSubtaskIDOnAdd(
            subtaskID: Self.mapKeyResultsID, parentTaskID: Self.planQ4ID)) {
            try await store.addSubtask(
                parentID: Self.planQ4ID,
                subtask: SubtaskItem(id: Self.mapKeyResultsID, title: "Clone"))
        }
        XCTAssertEqual(try bytes(at: planFile), planBytes, "nothing is written on collision")
        let collidingInMemory = await store.tasks
        let collidingOnDisk = try await diskTasks()
        XCTAssertEqual(collidingInMemory, collidingOnDisk, "inventory untouched")

        // Pinned scope: only the parent file's IDs collide — an ID that exists
        // in a different file (another top-level task) is accepted, because
        // every task file is its own ID namespace.
        let foreign = SubtaskItem(id: Self.readDeepWorkID, title: "ID from another file")
        let returned = try await store.addSubtask(parentID: Self.planQ4ID, subtask: foreign)
        XCTAssertEqual(returned.subtasks.last?.id, Self.readDeepWorkID)
        XCTAssertEqual(try parsedPlan().subtasks.last?.id, Self.readDeepWorkID)
    }

    // MARK: - Whole-file atomicity

    func testParentFileParsesThroughTheCodecAfterEveryOperation() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        let probe = SubtaskItem(title: "Atomicity probe", status: .inProgress, effort: .s)
        _ = try await store.addSubtask(parentID: Self.planQ4ID, subtask: probe)
        _ = try parsedPlan()

        _ = try await store.updateSubtask(
            parentID: Self.planQ4ID, subtaskID: Self.collectInputID) { $0.priority = .low }
        _ = try parsedPlan()

        _ = try await store.reorderSubtasks(
            parentID: Self.planQ4ID,
            siblingIDsInNewOrder: [Self.draftOKRID, Self.collectInputID, probe.id])
        _ = try parsedPlan()

        _ = try await store.setStatus(
            parentID: Self.planQ4ID, subtaskID: Self.collectInputID, to: .blocked)
        _ = try parsedPlan()

        try await store.deleteSubtask(parentID: Self.planQ4ID, subtaskID: Self.draftOKRID)
        let parsed = try parsedPlan()
        XCTAssertEqual(parsed.subtasks.map(\.id),
                       [Self.collectInputID, probe.id],
                       "the whole subtree went with the delete; the file is still valid "
                     + "Markdown/YAML after every operation")
        XCTAssertEqual(try body(of: planFile),
                       "\nDraft the Q4 roadmap covering hiring, platform work, "
                     + "and the mobile push.\n",
                       "the load-time body survives every operation byte-for-byte")
    }
}
