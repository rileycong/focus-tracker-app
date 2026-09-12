import XCTest
@testable import FocusTracker

/// Tests for the #17 subtask write passthroughs (`AppModel.addSubtask` /
/// `AppModel.updateSubtask` / `AppModel.deleteSubtask`): persistence through
/// the #8 `VaultStore` APIs, the typed `.noVaultConfigured` fail-closed
/// outcome (same as #16's `TaskWriteError`), unchanged store-error
/// surfacing, and the observable-state refresh from the store's
/// already-synced inventory (no reload).
///
/// Every vault-using test copies `fixtures/sample-vault/` into a fresh temp
/// directory — the repo fixture is never touched (repo convention) — and
/// changed fields are verified by parsing the file back from disk after each
/// step. The fixture's "Plan Q4 roadmap.md" carries the subtask tree
/// exercised here: task → Collect team input / Draft objectives and key
/// results → Define Q4 objectives / Map key results to objectives.
@MainActor
final class AppModelSubtaskTests: XCTestCase {

    // MARK: - Fixture access (same convention as #14/#7/#16 tests)

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
            .appendingPathComponent("AppModelSubtaskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        suiteName = "AppModelSubtaskTests-\(UUID().uuidString)"
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

    /// Parses the parent task's file back from disk — the write really
    /// landed and says what the model claims it says.
    private func parsedPlanQ4(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> TaskItem {
        let text = try String(
            contentsOf: tasksDirectory.appendingPathComponent("Plan Q4 roadmap.md"),
            encoding: .utf8)
        return try FrontmatterCodec.parseTask(text)
    }

    /// Depth-first search for a subtask by ID in a task's tree.
    private func subtask(
        _ id: UUID, in subtasks: [SubtaskItem], file: StaticString = #filePath,
        line: UInt = #line
    ) -> SubtaskItem? {
        for candidate in subtasks {
            if candidate.id == id { return candidate }
            if let deeper = subtask(id, in: candidate.children, file: file, line: line) {
                return deeper
            }
        }
        return nil
    }

    /// A fully-populated new subtask (every editable field set, PRD §5.4).
    private func makeNewSubtask(id: UUID = UUID()) -> SubtaskItem {
        SubtaskItem(
            id: id,
            title: "Review with the team",
            status: .inProgress,
            priority: .high,
            effort: .s,
            deadline: DeadlineDay.date(from: "2027-02-01"),
            notes: "Book the offsite room first.")
    }

    // MARK: - addSubtask (root: toParentSubtaskID nil)

    func testAddSubtaskUnderRootPersistsToDiskAndMirrorsInventory() async throws {
        let model = try await makeConfiguredModel()
        let newSubtask = makeNewSubtask()

        let updatedParent = try await model.addSubtask(
            parentID: Self.planQ4ID, subtask: newSubtask, toParentSubtaskID: nil)

        XCTAssertEqual(updatedParent.id, Self.planQ4ID)

        // Observable state refreshed from the store's synced inventory —
        // no reloadVault() needed (the #16/#17 mirroring choice).
        guard case .loaded = model.vaultState else {
            XCTFail("expected .loaded after add, got \(model.vaultState)")
            return
        }
        let mirrored = try XCTUnwrap(
            model.tasks.first { $0.id == Self.planQ4ID },
            "the exposed inventory carries the new subtask")
        XCTAssertNotNil(subtask(newSubtask.id, in: mirrored.subtasks))
        XCTAssertEqual(mirrored.subtasks.count, 3, "2 fixture subtasks + the new one")

        // Disk: parse the file back — the subtask is the last top-level
        // entry, with every field.
        let parsed = try parsedPlanQ4()
        XCTAssertEqual(parsed.subtasks.count, 3)
        let added = try XCTUnwrap(parsed.subtasks.last)
        XCTAssertEqual(added, newSubtask)
        XCTAssertEqual(added.title, "Review with the team")
        XCTAssertEqual(added.status, .inProgress)
        XCTAssertEqual(added.priority, .high)
        XCTAssertEqual(added.effort, .s)
        XCTAssertEqual(added.deadline, DeadlineDay.date(from: "2027-02-01"))
        XCTAssertEqual(added.notes, "Book the offsite room first.")
    }

    // MARK: - addSubtask (nested: under a level-2 subtask → depth 3)

    func testAddSubtaskUnderGrandchildNestsAtDepth3() async throws {
        let model = try await makeConfiguredModel()
        let newSubtask = makeNewSubtask()

        _ = try await model.addSubtask(
            parentID: Self.planQ4ID, subtask: newSubtask,
            toParentSubtaskID: Self.defineObjectivesID)

        // Disk: task → Draft OKRs (1) → Define Q4 objectives (2) → new (3).
        let parsed = try parsedPlanQ4()
        let draftOKR = try XCTUnwrap(subtask(Self.draftOKRID, in: parsed.subtasks))
        let defineObjectives = try XCTUnwrap(
            subtask(Self.defineObjectivesID, in: draftOKR.children))
        XCTAssertEqual(
            defineObjectives.children.last, newSubtask,
            "the new subtask is the level-2 subtask's last child — depth 3")
        XCTAssertEqual(defineObjectives.children.count, 1)

        // The observable inventory mirrors the depth-3 tree too.
        let mirrored = try XCTUnwrap(model.tasks.first { $0.id == Self.planQ4ID })
        let mirroredLevel2 = try XCTUnwrap(
            subtask(Self.defineObjectivesID, in: mirrored.subtasks))
        XCTAssertNotNil(subtask(newSubtask.id, in: mirroredLevel2.children))
    }

    // MARK: - updateSubtask (nil → set AND set → nil)

    func testEditNestedSubtaskNilToSetAndSetToNil() async throws {
        let model = try await makeConfiguredModel()
        // Fixture preconditions: "Collect team input" has effort + notes set
        // and priority/deadline nil.
        let original = try XCTUnwrap(
            subtask(Self.collectInputID, in: parsedPlanQ4().subtasks))
        XCTAssertNil(original.priority)
        XCTAssertNil(original.deadline)
        XCTAssertEqual(original.effort, .s)
        XCTAssertEqual(original.notes, "Gathered via the weekly sync and shared doc.")

        _ = try await model.updateSubtask(
            parentID: Self.planQ4ID, subtaskID: Self.collectInputID
        ) { target in
            target.priority = .high // nil → set
            target.deadline = DeadlineDay.date(from: "2027-03-15") // nil → set
            target.effort = nil // set → nil
            target.notes = nil // set → nil
        }

        // Disk: exactly the intended fields changed, both directions.
        let parsed = try parsedPlanQ4()
        let edited = try XCTUnwrap(subtask(Self.collectInputID, in: parsed.subtasks))
        XCTAssertEqual(edited.id, Self.collectInputID, "the ID is re-asserted (#8)")
        XCTAssertEqual(edited.priority, .high)
        XCTAssertEqual(edited.deadline, DeadlineDay.date(from: "2027-03-15"))
        XCTAssertNil(edited.effort)
        XCTAssertNil(edited.notes)
        XCTAssertEqual(edited.title, original.title, "untouched fields stay untouched")
        XCTAssertEqual(edited.status, original.status)

        // The observable inventory reflects the edit.
        let mirrored = try XCTUnwrap(model.tasks.first { $0.id == Self.planQ4ID })
        let mirroredEdited = try XCTUnwrap(
            subtask(Self.collectInputID, in: mirrored.subtasks))
        XCTAssertEqual(mirroredEdited.priority, .high)
        XCTAssertNil(mirroredEdited.effort)
    }

    func testEditSubtaskKeepsChildrenAndSiblingsIntact() async throws {
        let model = try await makeConfiguredModel()

        _ = try await model.updateSubtask(
            parentID: Self.planQ4ID, subtaskID: Self.draftOKRID
        ) { $0.title = "Draft OKRs (renamed)" }

        let parsed = try parsedPlanQ4()
        let edited = try XCTUnwrap(subtask(Self.draftOKRID, in: parsed.subtasks))
        XCTAssertEqual(edited.title, "Draft OKRs (renamed)")
        XCTAssertEqual(
            edited.children.map(\.id),
            [Self.defineObjectivesID, Self.mapKeyResultsID],
            "the subtree survives the rewrite (children edits are not part of the #8 contract)")
    }

    // MARK: - deleteSubtask (mid-level: subtree gone, siblings survive)

    func testDeleteMidLevelSubtaskRemovesSubtreeWithSiblingsSurviving() async throws {
        let model = try await makeConfiguredModel()
        // Precondition: "Draft objectives and key results" (level 1) carries
        // two children — deleting it takes the whole subtree with it.
        let before = try parsedPlanQ4()
        XCTAssertEqual(
            subtask(Self.draftOKRID, in: before.subtasks)?.children.count, 2)

        try await model.deleteSubtask(parentID: Self.planQ4ID, subtaskID: Self.draftOKRID)

        // Disk: the mid-level subtask and both of its children are gone;
        // the sibling branch survives intact.
        let parsed = try parsedPlanQ4()
        XCTAssertEqual(parsed.subtasks.map(\.id), [Self.collectInputID])
        XCTAssertNil(subtask(Self.draftOKRID, in: parsed.subtasks))
        XCTAssertNil(subtask(Self.defineObjectivesID, in: parsed.subtasks))
        XCTAssertNil(subtask(Self.mapKeyResultsID, in: parsed.subtasks))
        let sibling = try XCTUnwrap(subtask(Self.collectInputID, in: parsed.subtasks))
        XCTAssertEqual(sibling.status, .done, "the sibling branch is untouched")

        // The observable inventory mirrors the removal.
        let mirrored = try XCTUnwrap(model.tasks.first { $0.id == Self.planQ4ID })
        XCTAssertEqual(mirrored.subtasks.map(\.id), [Self.collectInputID])
    }

    // MARK: - noVaultConfigured (fail closed, same as #16)

    func testAddSubtaskWithoutConfiguredVaultThrowsNoVaultConfigured() async throws {
        let model = AppModel(settings: settings)
        await model.bootstrap()

        do {
            _ = try await model.addSubtask(
                parentID: Self.planQ4ID, subtask: makeNewSubtask(), toParentSubtaskID: nil)
            XCTFail("expected noVaultConfigured")
        } catch let error as AppModel.TaskWriteError {
            XCTAssertEqual(error, .noVaultConfigured, "fails closed — nowhere to write")
        }
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testUpdateSubtaskWithoutConfiguredVaultThrowsNoVaultConfigured() async throws {
        let model = AppModel(settings: settings)
        await model.bootstrap()

        do {
            _ = try await model.updateSubtask(
                parentID: Self.planQ4ID, subtaskID: Self.collectInputID
            ) { $0.title = "Should never land" }
            XCTFail("expected noVaultConfigured")
        } catch let error as AppModel.TaskWriteError {
            XCTAssertEqual(error, .noVaultConfigured)
        }
    }

    func testDeleteSubtaskWithoutConfiguredVaultThrowsNoVaultConfigured() async throws {
        let model = AppModel(settings: settings)
        await model.bootstrap()

        do {
            try await model.deleteSubtask(
                parentID: Self.planQ4ID, subtaskID: Self.collectInputID)
            XCTFail("expected noVaultConfigured")
        } catch let error as AppModel.TaskWriteError {
            XCTAssertEqual(error, .noVaultConfigured)
        }
    }

    // MARK: - Store errors surface unchanged

    func testAddSubtaskUnderUnknownParentSubtaskSurfacesStoreErrorUnchanged() async throws {
        let model = try await makeConfiguredModel()
        let unknownParent = UUID()

        do {
            _ = try await model.addSubtask(
                parentID: Self.planQ4ID, subtask: makeNewSubtask(),
                toParentSubtaskID: unknownParent)
            XCTFail("expected unknownSubtaskID")
        } catch let error as VaultStoreError {
            XCTAssertEqual(
                error, .unknownSubtaskID(subtaskID: unknownParent, parentTaskID: Self.planQ4ID),
                "store errors surface unchanged through the passthrough")
        }
        // Nothing was written: the file still parses to the fixture tree.
        let parsed = try parsedPlanQ4()
        XCTAssertEqual(parsed.subtasks.count, 2)
        XCTAssertEqual(model.tasks.count, 3)
    }

    func testDeleteUnknownSubtaskSurfacesStoreErrorUnchanged() async throws {
        let model = try await makeConfiguredModel()
        let unknown = UUID()

        do {
            try await model.deleteSubtask(parentID: Self.planQ4ID, subtaskID: unknown)
            XCTFail("expected unknownSubtaskID")
        } catch let error as VaultStoreError {
            XCTAssertEqual(error, .unknownSubtaskID(subtaskID: unknown, parentTaskID: Self.planQ4ID))
        }
        XCTAssertEqual(model.tasks.count, 3)
    }
}
