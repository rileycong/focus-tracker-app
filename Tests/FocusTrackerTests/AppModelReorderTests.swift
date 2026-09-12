import XCTest
@testable import FocusTracker

/// Tests for the #18 reorder passthroughs (`AppModel.reorderTasks` /
/// `AppModel.reorderSubtasks`): persistence through the #10
/// `VaultStore.applyOrdering` and #8 `VaultStore.reorderSubtasks` APIs, the
/// typed `.noVaultConfigured` fail-closed outcome (same as #16/#17), unchanged
/// store-error surfacing with nothing written, and the observable-state
/// refresh from the store's already-synced inventory (no reload — the pinned
/// apply-then-re-render choice).
///
/// Every vault-using test copies `fixtures/sample-vault/` into a fresh temp
/// directory — the repo fixture is never touched (repo convention) — and
/// outcomes are verified by parsing the affected files back from disk. The
/// task-reorder test follows the exact UI pipeline (#18): display-ordered IDs
/// → `ReorderArithmetic.newOrder` → `TaskOrdering.reorder` over the currently
/// persisted `order` values → the changed-only map → the passthrough.
@MainActor
final class AppModelReorderTests: XCTestCase {

    // MARK: - Fixture access (same convention as #14/#16/#17 tests)

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

    private var root: URL!
    private var vaultURL: URL!
    private var suiteName: String!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppModelReorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        suiteName = "AppModelReorderTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeConfiguredModel() async throws -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let model = AppModel(settings: settings)
        await model.bootstrap()
        return model
    }

    private var tasksDirectory: URL {
        vaultURL.appendingPathComponent("Tasks", isDirectory: true)
    }

    /// Parses a task file back from disk — the write really landed and says
    /// what the model claims it says.
    private func parsedTask(
        _ fileName: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> TaskItem {
        let text = try String(
            contentsOf: tasksDirectory.appendingPathComponent(fileName), encoding: .utf8)
        return try FrontmatterCodec.parseTask(text)
    }

    /// The fixture's exact disk bytes, for nothing-written assertions.
    private func diskBytes(_ fileName: String) throws -> Data {
        try Data(
            contentsOf: tasksDirectory.appendingPathComponent(fileName))
    }

    /// Creates a fresh unordered To Do task (No Project group) through the
    /// #16 passthrough, so a status group has two members to reorder.
    private func createToDoTask(id: UUID, title: String, in model: AppModel) async throws {
        _ = try await model.createTask(
            try TaskItem(
                id: id, title: title, categories: [Category(name: "C")], status: .toDo))
    }

    // MARK: - reorderTasks (task reorder within one status group)

    func testReorderTasksPersistsOrderValuesToDiskAndMirrorsInventory() async throws {
        let model = try await makeConfiguredModel()
        let alphaID = UUID()
        let betaID = UUID()
        try await createToDoTask(id: alphaID, title: "Alpha Task", in: model)
        try await createToDoTask(id: betaID, title: "Beta Task", in: model)

        // The exact #18 UI pipeline: display-ordered group IDs → pure
        // arithmetic (move "Beta Task" to the top) → changed-only updates.
        let group = TaskOrdering.Group(project: nil, status: .toDo)
        let displayIDs = try XCTUnwrap(
            TaskOrdering.displayOrder(of: model.tasks)[group],
            "both new tasks are unordered → inventory-position fallback order")
        XCTAssertEqual(displayIDs, [alphaID, betaID])
        let byID = Dictionary(uniqueKeysWithValues: model.tasks.map { ($0.id, $0) })
        let groupTasks = displayIDs.compactMap { byID[$0] }
        let currentOrders = Dictionary(
            uniqueKeysWithValues: groupTasks.map { ($0.id, $0.order) })
        let newOrder = try XCTUnwrap(
            ReorderArithmetic.newOrder(moving: betaID, to: 0, in: displayIDs))
        let updates = try TaskOrdering.reorder(
            currentDisplayOrder: displayIDs, newOrder: newOrder,
            currentOrders: currentOrders)
        XCTAssertEqual(updates, [betaID: 0, alphaID: 1], "changed-only, contiguous 0…n-1")

        let updated = try await model.reorderTasks(groupUpdates: updates)
        XCTAssertEqual(Set(updated.map(\.id)), Set([alphaID, betaID]))

        // Observable state refreshed from the store's synced inventory —
        // no reloadVault() needed (the #16/#17 mirroring choice).
        guard case .loaded = model.vaultState else {
            XCTFail("expected .loaded after reorder, got \(model.vaultState)")
            return
        }
        XCTAssertEqual(model.tasks.count, 5, "3 fixture tasks + the 2 created ones")
        XCTAssertEqual(model.tasks.first { $0.id == alphaID }?.order, 1)
        XCTAssertEqual(model.tasks.first { $0.id == betaID }?.order, 0)

        // Disk: parse the affected files back — the `order` values persisted.
        XCTAssertEqual(try parsedTask("Alpha Task.md").order, 1)
        XCTAssertEqual(try parsedTask("Beta Task.md").order, 0)
        XCTAssertEqual(
            try parsedTask("Plan Q4 roadmap.md").order, nil,
            "tasks outside the reordered group are untouched")

        // The order survives restart: a fresh model over the same vault
        // displays the group in the reordered sequence.
        let relaunched = AppModel(settings: settings)
        await relaunched.bootstrap()
        let redisplayed = try XCTUnwrap(
            TaskOrdering.displayOrder(of: relaunched.tasks)[group])
        XCTAssertEqual(
            redisplayed, [betaID, alphaID], "persisted order drives display after reload")
    }

    func testReorderTasksWithEmptyChangeSetWritesNothing() async throws {
        let model = try await makeConfiguredModel()
        let before = try diskBytes("Plan Q4 roadmap.md")

        let updated = try await model.reorderTasks(groupUpdates: [:])

        XCTAssertTrue(updated.isEmpty, "an empty change set is a no-op")
        XCTAssertEqual(try diskBytes("Plan Q4 roadmap.md"), before)
    }

    // MARK: - reorderSubtasks (sibling list order)

    func testReorderSubtasksPersistsListOrderToDiskAndMirrorsInventory() async throws {
        let model = try await makeConfiguredModel()
        // Fixture precondition: the top-level list is [Collect team input,
        // Draft OKRs]; the Draft branch carries two children.
        XCTAssertEqual(
            try parsedTask("Plan Q4 roadmap.md").subtasks.map(\.id),
            [Self.collectInputID, Self.draftOKRID])

        let updatedParent = try await model.reorderSubtasks(
            parentID: Self.planQ4ID, parentSubtaskID: nil,
            siblingIDsInNewOrder: [Self.draftOKRID, Self.collectInputID])

        XCTAssertEqual(updatedParent.id, Self.planQ4ID)
        XCTAssertEqual(
            updatedParent.subtasks.map(\.id),
            [Self.draftOKRID, Self.collectInputID])

        // Observable inventory mirrors the new list order.
        let mirrored = try XCTUnwrap(model.tasks.first { $0.id == Self.planQ4ID })
        XCTAssertEqual(
            mirrored.subtasks.map(\.id), [Self.draftOKRID, Self.collectInputID])

        // Disk: the list order persisted; the moved node's subtree traveled
        // with it and the sibling branch is intact.
        let parsed = try parsedTask("Plan Q4 roadmap.md")
        XCTAssertEqual(parsed.subtasks.map(\.id), [Self.draftOKRID, Self.collectInputID])
        let moved = try XCTUnwrap(parsed.subtasks.first { $0.id == Self.draftOKRID })
        XCTAssertEqual(
            moved.children.map(\.id),
            [Self.defineObjectivesID, Self.mapKeyResultsID],
            "the whole subtree travels with the node (#8 semantics)")
        let sibling = try XCTUnwrap(parsed.subtasks.first { $0.id == Self.collectInputID })
        XCTAssertEqual(sibling.status, .done, "the sibling branch is untouched")
    }

    func testReorderNestedChildrenListPersistsToDisk() async throws {
        let model = try await makeConfiguredModel()
        // Two children under the level-2 subtask, then reorder that children
        // list — `parentSubtaskID` set, any depth (#8/#18 contract).
        let childX = SubtaskItem(id: UUID(), title: "First pass")
        let childY = SubtaskItem(id: UUID(), title: "Second pass")
        _ = try await model.addSubtask(
            parentID: Self.planQ4ID, subtask: childX,
            toParentSubtaskID: Self.defineObjectivesID)
        _ = try await model.addSubtask(
            parentID: Self.planQ4ID, subtask: childY,
            toParentSubtaskID: Self.defineObjectivesID)

        _ = try await model.reorderSubtasks(
            parentID: Self.planQ4ID, parentSubtaskID: Self.defineObjectivesID,
            siblingIDsInNewOrder: [childY.id, childX.id])

        // Disk: the nested list order persisted; the top-level list untouched.
        let parsed = try parsedTask("Plan Q4 roadmap.md")
        XCTAssertEqual(
            parsed.subtasks.map(\.id), [Self.collectInputID, Self.draftOKRID])
        let defineObjectives = try XCTUnwrap(
            parsed.subtasks.first { $0.id == Self.draftOKRID }?
                .children.first { $0.id == Self.defineObjectivesID })
        XCTAssertEqual(defineObjectives.children.map(\.id), [childY.id, childX.id])
    }

    // MARK: - noVaultConfigured (fail closed, same as #16/#17)

    func testReorderTasksWithoutConfiguredVaultThrowsNoVaultConfigured() async throws {
        let model = AppModel(settings: settings)
        await model.bootstrap()

        do {
            _ = try await model.reorderTasks(groupUpdates: [UUID(): 0])
            XCTFail("expected noVaultConfigured")
        } catch let error as AppModel.TaskWriteError {
            XCTAssertEqual(error, .noVaultConfigured, "fails closed — nowhere to write")
        }
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testReorderSubtasksWithoutConfiguredVaultThrowsNoVaultConfigured() async throws {
        let model = AppModel(settings: settings)
        await model.bootstrap()

        do {
            _ = try await model.reorderSubtasks(
                parentID: Self.planQ4ID, parentSubtaskID: nil,
                siblingIDsInNewOrder: [Self.collectInputID, Self.draftOKRID])
            XCTFail("expected noVaultConfigured")
        } catch let error as AppModel.TaskWriteError {
            XCTAssertEqual(error, .noVaultConfigured)
        }
    }

    // MARK: - Store errors surface unchanged, nothing written

    func testReorderTasksWithUnknownIDSurfacesStoreErrorAndWritesNothing() async throws {
        let model = try await makeConfiguredModel()
        let unknown = UUID()
        let before = try diskBytes("Plan Q4 roadmap.md")

        do {
            _ = try await model.reorderTasks(groupUpdates: [unknown: 0])
            XCTFail("expected unknownTaskID")
        } catch let error as VaultStoreError {
            XCTAssertEqual(
                error, .unknownTaskID(unknown),
                "store errors surface unchanged through the passthrough")
        }

        // Nothing was written and the observable state is untouched.
        XCTAssertEqual(try diskBytes("Plan Q4 roadmap.md"), before)
        XCTAssertEqual(model.tasks.count, 3)
        XCTAssertTrue(model.tasks.allSatisfy { $0.order == nil })
    }

    func testReorderSubtasksRejectsNonPermutationAndWritesNothing() async throws {
        let model = try await makeConfiguredModel()
        let before = try diskBytes("Plan Q4 roadmap.md")

        do {
            _ = try await model.reorderSubtasks(
                parentID: Self.planQ4ID, parentSubtaskID: nil,
                siblingIDsInNewOrder: [Self.collectInputID])
            XCTFail("expected reorderNotExactPermutation")
        } catch let error as VaultStoreError {
            guard case .reorderNotExactPermutation(let current, let proposed) = error else {
                XCTFail("expected reorderNotExactPermutation, got \(error)")
                return
            }
            XCTAssertEqual(current, [Self.collectInputID, Self.draftOKRID])
            XCTAssertEqual(proposed, [Self.collectInputID])
        }

        XCTAssertEqual(try diskBytes("Plan Q4 roadmap.md"), before)
        XCTAssertEqual(
            model.tasks.first { $0.id == Self.planQ4ID }?.subtasks.map(\.id),
            [Self.collectInputID, Self.draftOKRID])
    }

    func testReorderSubtasksWithUnknownParentOrParentSubtaskSurfacesStoreError()
        async throws
    {
        let model = try await makeConfiguredModel()
        let unknownParentTask = UUID()
        let unknownParentSubtask = UUID()

        do {
            _ = try await model.reorderSubtasks(
                parentID: unknownParentTask, parentSubtaskID: nil,
                siblingIDsInNewOrder: [Self.collectInputID])
            XCTFail("expected unknownTaskID")
        } catch let error as VaultStoreError {
            XCTAssertEqual(error, .unknownTaskID(unknownParentTask))
        }

        do {
            _ = try await model.reorderSubtasks(
                parentID: Self.planQ4ID, parentSubtaskID: unknownParentSubtask,
                siblingIDsInNewOrder: [Self.collectInputID, Self.draftOKRID])
            XCTFail("expected unknownSubtaskID")
        } catch let error as VaultStoreError {
            XCTAssertEqual(
                error,
                .unknownSubtaskID(
                    subtaskID: unknownParentSubtask, parentTaskID: Self.planQ4ID))
        }
        XCTAssertEqual(model.tasks.count, 3, "nothing written by either failure")
    }
}
