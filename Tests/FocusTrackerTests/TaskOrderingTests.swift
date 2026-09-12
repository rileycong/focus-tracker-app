import XCTest
@testable import FocusTracker

/// Manual task ordering (issue #10, PRD §8.4): the pure `TaskOrdering`
/// helpers, the `order` codec round-trip/byte-stability, and the
/// `VaultStore.applyOrdering(groupUpdates:)` wrapper.
///
/// Every vault-using test copies `fixtures/sample-vault/` into a fresh temp
/// directory — the repo fixture is never touched (same convention as the
/// #6–#9 tests).
final class TaskOrderingTests: XCTestCase {

    // MARK: - Pure helper fixtures

    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()
    private static let d = UUID()

    private static let workGroup = TaskOrdering.Group(
        project: Project(name: "Work"), status: .inProgress)

    private func task(
        _ id: UUID, project: Project? = nil, status: TaskStatus = .toDo, order: Int? = nil
    ) -> TaskItem {
        // Categories are non-empty, so the throwing initializer cannot fail.
        try! TaskItem(
            id: id, title: id.uuidString, categories: [Category(name: "C")],
            status: status, project: project, order: order)
    }

    // MARK: - Pure reorder: permutation validation

    func testReorderRejectsMissingExtraAndDuplicateIDs() throws {
        let ids = [Self.a, Self.b, Self.c]
        let cases: [(name: String, proposed: [UUID])] = [
            ("missing", [Self.a, Self.b]),
            ("extra", [Self.a, Self.b, Self.c, Self.d]),
            ("duplicate", [Self.a, Self.a, Self.b]),
        ]
        for (name, proposed) in cases {
            XCTAssertThrowsError(
                try TaskOrdering.reorder(
                    currentDisplayOrder: ids, newOrder: proposed,
                    currentOrders: [Self.a: 0, Self.b: 1, Self.c: 2]),
                name
            ) { error in
                XCTAssertEqual(
                    error as? VaultStoreError,
                    .reorderNotExactPermutation(currentSiblings: ids, proposedOrder: proposed),
                    name)
            }
        }
    }

    // MARK: - Pure reorder: renumbering and minimal change set

    func testReorderRenumbersContiguouslyAndDeterministically() throws {
        let updates = try TaskOrdering.reorder(
            currentDisplayOrder: [Self.a, Self.b, Self.c],
            newOrder: [Self.c, Self.a, Self.b],
            currentOrders: [Self.a: 0, Self.b: 1, Self.c: 2])
        XCTAssertEqual(updates, [Self.c: 0, Self.a: 1, Self.b: 2])
        let again = try TaskOrdering.reorder(
            currentDisplayOrder: [Self.a, Self.b, Self.c],
            newOrder: [Self.c, Self.a, Self.b],
            currentOrders: [Self.a: 0, Self.b: 1, Self.c: 2])
        XCTAssertEqual(again, updates, "the same input must renumber identically")
    }

    func testReorderReturnsMinimalChangeSet() throws {
        let updates = try TaskOrdering.reorder(
            currentDisplayOrder: [Self.a, Self.b, Self.c],
            newOrder: [Self.b, Self.a, Self.c],
            currentOrders: [Self.a: 0, Self.b: 1, Self.c: 2])
        XCTAssertEqual(updates, [Self.b: 0, Self.a: 1], "only genuinely changed IDs")
        XCTAssertFalse(updates.keys.contains(Self.c), "c keeps its value → omitted")
    }

    func testReorderNoOpYieldsEmptyMap() throws {
        XCTAssertEqual(
            try TaskOrdering.reorder(
                currentDisplayOrder: [Self.a, Self.b, Self.c],
                newOrder: [Self.a, Self.b, Self.c],
                currentOrders: [Self.a: 0, Self.b: 1, Self.c: 2]),
            [:])
    }

    func testReorderUnorderedToOrderedCountsAsChanged() throws {
        XCTAssertEqual(
            try TaskOrdering.reorder(
                currentDisplayOrder: [Self.a, Self.b],
                newOrder: [Self.a, Self.b],
                currentOrders: [Self.a: nil, Self.b: nil]),
            [Self.a: 0, Self.b: 1])
    }

    func testReorderRenumberHandEditedNonContiguousValues() throws {
        XCTAssertEqual(
            try TaskOrdering.reorder(
                currentDisplayOrder: [Self.a, Self.b],
                newOrder: [Self.b, Self.a],
                currentOrders: [Self.a: 5, Self.b: 9]),
            [Self.b: 0, Self.a: 1])
    }

    // MARK: - Pure display-order resolution

    func testDisplayOrderOrderedFirstAscendingUnorderedLastFilenameSorted() {
        // Input is the filename-sorted inventory order: a, b, c, d.
        let tasks = [
            task(Self.a, order: 2), task(Self.b), task(Self.c, order: 1), task(Self.d),
        ]
        XCTAssertEqual(
            TaskOrdering.displayOrder(of: tasks)[
                TaskOrdering.Group(project: nil, status: .toDo)],
            [Self.c, Self.a, Self.b, Self.d])
    }

    func testDisplayOrderTieBreaksEqualOrdersByFilenameSortedPosition() {
        let tasks = [task(Self.a, order: 1), task(Self.b, order: 1), task(Self.c, order: 0)]
        XCTAssertEqual(
            TaskOrdering.displayOrder(of: tasks)[
                TaskOrdering.Group(project: nil, status: .toDo)],
            [Self.c, Self.a, Self.b])
    }

    func testDisplayOrderWithNoOrdersIsExactlyTheInputOrder() {
        let tasks = [task(Self.a), task(Self.b), task(Self.c)]
        XCTAssertEqual(
            TaskOrdering.displayOrder(of: tasks)[
                TaskOrdering.Group(project: nil, status: .toDo)],
            [Self.a, Self.b, Self.c])
    }

    func testDisplayOrderNegativeSortsBeforeZeroAndUnordered() {
        let tasks = [task(Self.a, order: 0), task(Self.b, order: -1), task(Self.c)]
        XCTAssertEqual(
            TaskOrdering.displayOrder(of: tasks)[
                TaskOrdering.Group(project: nil, status: .toDo)],
            [Self.b, Self.a, Self.c])
    }

    func testDisplayOrderSplitsGroupsByProjectAndStatus() {
        let tasks = [
            task(Self.a, project: Project(name: "Work"), status: .toDo),
            task(Self.b, project: Project(name: "Work"), status: .inProgress),
            task(Self.c, status: .toDo),
            task(Self.d, project: Project(name: "Work"), status: .toDo, order: 0),
        ]
        let result = TaskOrdering.displayOrder(of: tasks)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(
            result[TaskOrdering.Group(project: Project(name: "Work"), status: .toDo)],
            [Self.d, Self.a])
        XCTAssertEqual(
            result[TaskOrdering.Group(project: Project(name: "Work"), status: .inProgress)],
            [Self.b])
        XCTAssertEqual(result[TaskOrdering.Group(project: nil, status: .toDo)], [Self.c])
    }

    func testDisplayOrderIsDeterministicForIdenticalInput() {
        let tasks = [
            task(Self.a, order: 3), task(Self.b), task(Self.c, order: 1), task(Self.d),
        ]
        XCTAssertEqual(TaskOrdering.displayOrder(of: tasks), TaskOrdering.displayOrder(of: tasks))
    }

    // MARK: - Codec: fixture access (read-only)

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault/Tasks", isDirectory: true)

    private func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: Self.fixturesDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    private static let testIDString = "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02"
    private static let testID = UUID(uuidString: testIDString)!

    private let baseYAML = """
    id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
    title: Test task
    status: To Do
    categories:
      - Planning
    """

    private func fileText(yaml: String, body: String = "\nSome body.\n") -> String {
        let frontmatter = yaml.hasSuffix("\n") ? yaml : yaml + "\n"
        return "---\n" + frontmatter + "---\n" + body
    }

    private func assertThrows(
        _ expression: @autoclosure () throws -> some Any,
        _ expected: FrontmatterError,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? FrontmatterError, expected,
                "expected \(expected), got \(error) \(message())",
                file: file, line: line)
        }
    }

    // MARK: - Codec: order round-trip

    func testOrderRoundTripsLosslesslyIncludingZeroAndNegatives() throws {
        for value in [0, 1, -3, 42, Int.max, Int.min] {
            let task = try TaskItem(
                title: "T", categories: [Category(name: "C")], order: value)
            let encoded = FrontmatterCodec.encode(task: task, body: "")
            XCTAssertTrue(encoded.contains("\norder: \(value)\n"), "missing key: \(encoded)")
            let parsed = try FrontmatterCodec.parseTask(encoded)
            XCTAssertEqual(parsed.order, value)
            let encodedAgain = FrontmatterCodec.encode(task: parsed, body: "")
            XCTAssertEqual(encodedAgain, encoded, "byte instability for order \(value)")
            XCTAssertEqual(try FrontmatterCodec.parseTask(encodedAgain).order, value)
        }
    }

    func testAbsentOrderDecodesAsUnorderedAndKeyIsOmitted() throws {
        let task = try FrontmatterCodec.parseTask(fileText(yaml: baseYAML))
        XCTAssertNil(task.order)
        let encoded = FrontmatterCodec.encode(task: task, body: "\nBody.\n")
        XCTAssertFalse(encoded.contains("order"), "nil must never serialize: \(encoded)")
    }

    func testExplicitNullOrderDecodesAsUnorderedAndStaysOmitted() throws {
        for variant in ["order:", "order: null", "order: ~"] {
            let task = try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\n" + variant))
            XCTAssertNil(task.order, variant)
            let encoded = FrontmatterCodec.encode(task: task, body: "\nBody.\n")
            XCTAssertFalse(encoded.contains("order"), "\(variant) must not re-serialize")
        }
    }

    func testNonIntegerOrderThrowsTypedErrorWithoutCoercion() throws {
        let scalarCases: [(yaml: String, value: String)] = [
            ("order: '5'", "5"),
            ("order: \"5\"", "5"),
            ("order: 5.0", "5.0"),
            ("order: true", "true"),
            ("order: abc", "abc"),
            ("order: 99999999999999999999", "99999999999999999999"),
        ]
        for (yaml, value) in scalarCases {
            assertThrows(
                try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\n" + yaml)),
                .wrongType(field: "order", value: value, expected: "integer"), yaml)
        }
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\norder: [1]\n")),
            .wrongType(field: "order", value: "[1 items]", expected: "integer"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\norder: {a: 1}\n")),
            .wrongType(field: "order", value: "{mapping}", expected: "integer"))
    }

    func testOrderKeyRejectedOnSubtasks() throws {
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\nsubtasks:\n"
                + "  - id: \(Self.testIDString)\n"
                + "    title: Sub\n"
                + "    status: To Do\n"
                + "    order: 1\n")),
            .unknownKeys(["order"]))
    }

    func testOldFixturesWithoutOrderStillParse() throws {
        for name in ["Plan Q4 roadmap.md", "Read Deep Work.md", "Renew passport.md"] {
            let task = try FrontmatterCodec.parseTask(try fixtureText(name))
            XCTAssertNil(task.order, name)
        }
    }

    // MARK: - Codec: key slot and byte stability

    func testOrderKeyIsWrittenBetweenNotesAndSubtasks() throws {
        let task = try TaskItem(
            title: "Ordered", categories: [Category(name: "Planning")], status: .toDo,
            notes: "N", order: 3,
            subtasks: [SubtaskItem(title: "Sub", status: .toDo)])
        let encoded = FrontmatterCodec.encode(task: task, body: "")
        let notesStart = try XCTUnwrap(encoded.range(of: "\nnotes: N\n")?.lowerBound)
        let orderStart = try XCTUnwrap(encoded.range(of: "\norder: 3\n")?.lowerBound)
        let subtasksStart = try XCTUnwrap(encoded.range(of: "\nsubtasks:\n")?.lowerBound)
        XCTAssertLessThan(notesStart, orderStart)
        XCTAssertLessThan(orderStart, subtasksStart)
    }

    func testEncodeTaskWithoutOrderIsByteIdenticalToPreIssueFormat() throws {
        let task = try TaskItem(
            id: Self.testID, title: "Test task", categories: [Category(name: "Planning")],
            status: .toDo, notes: "Keep.")
        XCTAssertEqual(
            FrontmatterCodec.encode(task: task, body: "\nBody.\n"),
            "---\n"
                + "id: \(Self.testIDString)\n"
                + "title: Test task\n"
                + "status: To Do\n"
                + "categories:\n"
                + "  - Planning\n"
                + "notes: Keep.\n"
                + "---\n"
                + "\nBody.\n")
    }

    // MARK: - Wrapper fixture access

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private static let planQ4ID = UUID(uuidString: "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02")!
    private static let readDeepWorkID = UUID(uuidString: "c9d1e3f5-2a4b-4c6d-8e0f-7b9a1d3c5e69")!
    private static let renewPassportID = UUID(uuidString: "a2b8c4d6-9e1f-4a7b-b3c5-8d2e6f4a1c47")!
    private static let collectInputID = UUID(uuidString: "8a4c2e6f-1d3b-4f5a-8b9c-2e7d1a4c6e08")!

    private var root: URL!
    private var vaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TaskOrderingTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Wrapper helpers

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

    private func makeStore() -> VaultStore {
        VaultStore(vaultURL: vaultURL)
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

    /// Creates the two extra same-group tasks used by the wrapper tests: the
    /// (Work, In Progress) group becomes A First task < Plan Q4 roadmap <
    /// Z Last task in filename-sorted inventory order, all unordered.
    private func createWorkGroupTasks(in store: VaultStore) async throws -> (UUID, UUID) {
        let aFirst = try TaskItem(
            title: "A First task", categories: [Category(name: "Planning")],
            status: .inProgress, project: Project(name: "Work"))
        _ = try await store.create(aFirst)
        let zLast = try TaskItem(
            title: "Z Last task", categories: [Category(name: "Planning")],
            status: .inProgress, project: Project(name: "Work"))
        _ = try await store.create(zLast)
        return (aFirst.id, zLast.id)
    }

    /// Replaces the fixture's "Plan Q4 roadmap.md" with different valid content
    /// (same ID) — the external edit the staleness guard must catch mid-batch.
    private func externallyRewritePlan() throws {
        let external = """
        ---
        id: \(Self.planQ4ID.uuidString)
        title: Plan Q4 roadmap
        status: In Progress
        categories:
          - Planning
          - Work
        ---

        Externally edited body.

        """
        try Data(external.utf8).write(to: planFile)
    }

    // MARK: - Wrapper: batch persistence and display rule

    func testBatchPersistsToAllAffectedFilesAndSyncsInventoryWithoutReload() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let (aFirstID, zLastID) = try await createWorkGroupTasks(in: store)

        // Compose the batch exactly like the #18 UI will: resolve the current
        // display order, compute the changed-only updates, apply.
        let tasks = await store.tasks
        let display = TaskOrdering.displayOrder(of: tasks)[Self.workGroup]
        XCTAssertEqual(display, [aFirstID, Self.planQ4ID, zLastID],
                       "unordered tasks display last, filename-sorted")
        let updates = try TaskOrdering.reorder(
            currentDisplayOrder: try XCTUnwrap(display),
            newOrder: [zLastID, aFirstID, Self.planQ4ID],
            currentOrders: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.order) }))
        XCTAssertEqual(updates, [zLastID: 0, aFirstID: 1, Self.planQ4ID: 2])

        let applied = try await store.applyOrdering(groupUpdates: updates)
        XCTAssertEqual(Set(applied.map(\.id)), Set([aFirstID, Self.planQ4ID, zLastID]))

        // Parse-back with a fresh store: the batch persisted to all files.
        let fresh = makeStore()
        let inventory = try requireLoaded(await fresh.load())
        let byID = Dictionary(uniqueKeysWithValues: inventory.tasks.map { ($0.id, $0) })
        XCTAssertEqual(byID[zLastID]?.order, 0)
        XCTAssertEqual(byID[aFirstID]?.order, 1)
        XCTAssertEqual(byID[Self.planQ4ID]?.order, 2)

        // Inventory consistency without reload: same tasks as a fresh load.
        let storeTasks = await store.tasks
        XCTAssertEqual(storeTasks, inventory.tasks)
        let storeCount = await store.taskCount
        XCTAssertEqual(storeCount, inventory.tasks.count)
        if case .task(let lookedUp) = await store.lookup(Self.planQ4ID) {
            XCTAssertEqual(lookedUp.order, 2)
        } else {
            XCTFail("expected lookup to find the plan task")
        }

        // The new display order is deterministic and reflects the reorder.
        XCTAssertEqual(
            TaskOrdering.displayOrder(of: storeTasks)[Self.workGroup],
            [zLastID, aFirstID, Self.planQ4ID])
    }

    func testNoOpAndEmptyBatchWriteNothing() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        _ = try await store.applyOrdering(groupUpdates: [Self.planQ4ID: 0])
        let afterFirst = try bytes(at: planFile)

        // Same value again → skipped (no write, no byte-record churn).
        let applied = try await store.applyOrdering(groupUpdates: [Self.planQ4ID: 0])
        XCTAssertEqual(applied, [])
        XCTAssertEqual(try bytes(at: planFile), afterFirst, "no-op must not touch the file")

        // Empty batch → nothing.
        let appliedEmpty = try await store.applyOrdering(groupUpdates: [:])
        XCTAssertEqual(appliedEmpty, [])
        XCTAssertEqual(try bytes(at: planFile), afterFirst)
    }

    func testDisplayRuleFromStoreTasksIsDeterministicWhileAllUnordered() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let (aFirstID, zLastID) = try await createWorkGroupTasks(in: store)

        let tasks = await store.tasks
        let display = TaskOrdering.displayOrder(of: tasks)
        XCTAssertEqual(display[Self.workGroup], [aFirstID, Self.planQ4ID, zLastID])
        XCTAssertEqual(
            display[TaskOrdering.Group(project: nil, status: .dropped)], [Self.readDeepWorkID])
        XCTAssertEqual(
            display[TaskOrdering.Group(project: nil, status: .blocked)], [Self.renewPassportID])
        XCTAssertEqual(TaskOrdering.displayOrder(of: tasks), display, "deterministic")
    }

    // MARK: - Wrapper: validation

    func testUnknownIDFailsWithNothingWritten() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let unknown = UUID()
        let planBytes = try bytes(at: planFile)

        await expectStoreError(.unknownTaskID(unknown)) {
            try await store.applyOrdering(groupUpdates: [Self.planQ4ID: 0, unknown: 1])
        }
        XCTAssertEqual(try bytes(at: planFile), planBytes, "nothing is written on rejection")
        let tasks = await store.tasks
        XCTAssertTrue(tasks.allSatisfy { $0.order == nil }, "inventory untouched")
        XCTAssertEqual(tasks.count, 3)
    }

    func testSubtaskIDFailsWithNothingWritten() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let planBytes = try bytes(at: planFile)

        await expectStoreError(.notTopLevelTask(Self.collectInputID)) {
            try await store.applyOrdering(groupUpdates: [Self.collectInputID: 0])
        }
        XCTAssertEqual(try bytes(at: planFile), planBytes, "nothing is written on rejection")
    }

    // MARK: - Wrapper: mid-batch staleness conflict

    func testStalenessConflictMidBatchSplitsCompletedAndPendingAndRetryConverges() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let (aFirstID, zLastID) = try await createWorkGroupTasks(in: store)

        // Application order is inventory order: A First task, Plan Q4 roadmap,
        // Z Last task. Externally rewrite the second file so the batch hits
        // the staleness guard after the first write succeeded.
        try externallyRewritePlan()
        let planBytesBefore = try bytes(at: planFile)
        let zLastBytesBefore = try bytes(at: taskFile("Z Last task.md"))
        let updates = [aFirstID: 0, Self.planQ4ID: 1, zLastID: 2]

        do {
            _ = try await store.applyOrdering(groupUpdates: updates)
            XCTFail("expected a mid-batch failure")
        } catch let error as VaultStoreError {
            XCTAssertEqual(
                error,
                .orderingBatchIncomplete(
                    completed: [aFirstID: "A First task.md"],
                    pending: [Self.planQ4ID: "Plan Q4 roadmap.md", zLastID: "Z Last task.md"],
                    underlying: .vaultChangedExternally(
                        id: Self.planQ4ID, fileName: "Plan Q4 roadmap.md")))
        }

        // Not cross-file atomic (documented): the first file carries its new
        // order; the externally changed file and the not-attempted one are
        // byte-identical to before the batch.
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: taskFile("A First task.md"))).order, 0)
        XCTAssertEqual(try bytes(at: planFile), planBytesBefore, "failing file untouched")
        XCTAssertEqual(try bytes(at: taskFile("Z Last task.md")), zLastBytesBefore)
        XCTAssertNil(try FrontmatterCodec.parseTask(text(at: planFile)).order)

        // Documented recovery: load() + retry — the whole batch converges
        // (the already-ordered task is a no-op skip) and the external edit is
        // preserved, not overwritten from a stale copy.
        _ = try requireLoaded(await store.load())
        _ = try await store.applyOrdering(groupUpdates: updates)

        let fresh = makeStore()
        let inventory = try requireLoaded(await fresh.load())
        let byID = Dictionary(uniqueKeysWithValues: inventory.tasks.map { ($0.id, $0) })
        XCTAssertEqual(byID[aFirstID]?.order, 0)
        XCTAssertEqual(byID[Self.planQ4ID]?.order, 1)
        XCTAssertEqual(byID[zLastID]?.order, 2)
        XCTAssertEqual(try body(of: planFile), "\nExternally edited body.\n")
        XCTAssertNil(byID[Self.planQ4ID]?.notes, "external field removals persist")
        XCTAssertTrue(byID[Self.planQ4ID]?.subtasks.isEmpty ?? false)
    }
}
