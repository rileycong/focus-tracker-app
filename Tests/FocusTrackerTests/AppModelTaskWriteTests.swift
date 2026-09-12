import XCTest
@testable import FocusTracker

/// Tests for the #16 task write passthroughs (`AppModel.createTask` /
/// `AppModel.updateTask`): persistence through `VaultStore` (#7 mechanics —
/// slug filename + collision suffix, ID↔filename-mapped updates, atomic
/// writes), typed error surfacing, and the observable-state refresh from the
/// store's already-synced inventory (no reload needed).
///
/// Every vault-using test copies `fixtures/sample-vault/` into a fresh temp
/// directory — the repo fixture is never touched (repo convention); changed
/// fields are verified by parsing the file back from disk.
@MainActor
final class AppModelTaskWriteTests: XCTestCase {

    // MARK: - Fixture access (same convention as #14/#7 tests)

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private static let planQ4ID = UUID(uuidString: "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02")!
    private static let readDeepWorkID = UUID(uuidString: "c9d1e3f5-2a4b-4c6d-8e0f-7b9a1d3c5e69")!

    private var root: URL!
    private var vaultURL: URL!
    private var suiteName: String!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppModelTaskWriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        suiteName = "AppModelTaskWriteTests-\(UUID().uuidString)"
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

    private func taskFile(_ name: String) -> URL {
        tasksDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func text(at url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Parses a task file back from disk — the write really landed and says
    /// what the model claims it says.
    private func parsedTask(
        _ fileName: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> TaskItem {
        try FrontmatterCodec.parseTask(text(at: taskFile(fileName), file: file, line: line))
    }

    private func fileNamesInTasksDirectory() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tasksDirectory.path(percentEncoded: false))
            .sorted()
    }

    /// A fully-populated new task (every form field set, PRD §6.4–§6.8).
    private func makeNewTask(id: UUID = UUID()) throws -> TaskItem {
        try TaskItem(
            id: id,
            title: "Write blog post",
            categories: [Category(name: "Writing"), Category(name: "Work")],
            status: .inProgress,
            project: Project(name: "Writing"),
            priority: .medium,
            effort: .m,
            deadline: DeadlineDay.date(from: "2026-11-01"),
            notes: "Draft the outline first.")
    }

    // MARK: - createTask

    func testCreateTaskPersistsToDiskAndAppearsInExposedInventory() async throws {
        let model = try await makeConfiguredModel()
        let task = try makeNewTask()

        let created = try await model.createTask(task)

        XCTAssertEqual(created.id, task.id, "the created task keeps the model's ID")

        // Observable state refreshed from the store's synced inventory —
        // no reloadVault() needed (the #16 mirroring choice).
        guard case .loaded = model.vaultState else {
            XCTFail("expected .loaded after create, got \(model.vaultState)")
            return
        }
        XCTAssertTrue(model.tasks.contains { $0.id == task.id })
        XCTAssertEqual(model.tasks.count, 4, "3 fixture tasks + the new one")

        // Disk: file exists at the slug, and parsing it back shows the fields.
        let parsed = try parsedTask("Write blog post.md")
        XCTAssertEqual(parsed.id, task.id)
        XCTAssertEqual(parsed.title, "Write blog post")
        XCTAssertEqual(parsed.status, .inProgress)
        XCTAssertEqual(parsed.project?.name, "Writing")
        XCTAssertEqual(parsed.priority, .medium)
        XCTAssertEqual(parsed.effort, .m)
        XCTAssertEqual(parsed.deadline, DeadlineDay.date(from: "2026-11-01"))
        XCTAssertEqual(parsed.notes, "Draft the outline first.")
        XCTAssertEqual(parsed.categories.map(\.name), ["Writing", "Work"])
    }

    func testCreateTaskSortsIntoTheFilenameSortedExposedOrder() async throws {
        let model = try await makeConfiguredModel()
        let task = try TaskItem(
            title: "Aardvark task", categories: [Category(name: "Inbox")])

        _ = try await model.createTask(task)

        XCTAssertEqual(
            model.tasks.first?.title, "Aardvark task",
            "the exposed list mirrors the store's filename-sorted inventory")
    }

    func testCreateTaskWithExistingTitleGetsTheCollisionSuffix() async throws {
        let model = try await makeConfiguredModel()
        let task = try TaskItem(
            title: "Plan Q4 roadmap", categories: [Category(name: "Planning")])

        _ = try await model.createTask(task)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: taskFile("Plan Q4 roadmap-2.md").path(percentEncoded: false)),
            "create is additive: the second task with the same title gets -2 (#7)")
        XCTAssertEqual(model.tasks.count, 4)
        XCTAssertEqual(
            Set(model.tasks.filter { $0.title == "Plan Q4 roadmap" }.map(\.id)).count, 2,
            "both tasks exist under distinct IDs")
    }

    func testCreateTaskWithDuplicateIDThrowsTypedAndChangesNothing() async throws {
        let model = try await makeConfiguredModel()
        let task = try TaskItem(
            id: Self.planQ4ID, title: "Impostor", categories: [Category(name: "Inbox")])

        do {
            _ = try await model.createTask(task)
            XCTFail("expected duplicateTaskIDOnCreate")
        } catch let error as VaultStoreError {
            XCTAssertEqual(error, .duplicateTaskIDOnCreate(Self.planQ4ID))
        }
        XCTAssertEqual(model.tasks.count, 3, "nothing was written")
        XCTAssertEqual(try fileNamesInTasksDirectory().count, 3, "no new file on disk")
    }

    func testCreateTaskWithoutConfiguredVaultThrowsNoVaultConfigured() async throws {
        let model = AppModel(settings: settings)
        await model.bootstrap()

        do {
            _ = try await model.createTask(try makeNewTask())
            XCTFail("expected noVaultConfigured")
        } catch let error as AppModel.TaskWriteError {
            XCTAssertEqual(error, .noVaultConfigured, "fails closed — nowhere to write")
        }
        XCTAssertTrue(model.tasks.isEmpty)
    }

    // MARK: - updateTask

    func testUpdateTaskPersistsChangedFieldsToDisk() async throws {
        let model = try await makeConfiguredModel()
        let original = try XCTUnwrap(model.tasks.first { $0.id == Self.readDeepWorkID })
        var updated = original
        updated.status = .inProgress
        updated.priority = .high
        updated.effort = .m
        updated.deadline = DeadlineDay.date(from: "2026-12-24")
        updated.notes = "Picked back up."
        updated.categories = [Category(name: "Learning"), Category(name: "Work")]
        updated.project = Project(name: "Writing")

        let persisted = try await model.updateTask(updated)

        XCTAssertEqual(persisted.id, original.id)
        XCTAssertTrue(model.tasks.contains { $0.id == original.id && $0.priority == .high },
                      "the exposed inventory reflects the change")

        // Parse the file back from disk: changed fields changed, untouched
        // fields (title here) unchanged.
        let parsed = try parsedTask("Read Deep Work.md")
        XCTAssertEqual(parsed.title, "Read Deep Work")
        XCTAssertEqual(parsed.status, .inProgress)
        XCTAssertEqual(parsed.priority, .high)
        XCTAssertEqual(parsed.effort, .m)
        XCTAssertEqual(parsed.deadline, DeadlineDay.date(from: "2026-12-24"))
        XCTAssertEqual(parsed.notes, "Picked back up.")
        XCTAssertEqual(parsed.categories.map(\.name), ["Learning", "Work"])
        XCTAssertEqual(parsed.project?.name, "Writing")
    }

    func testUpdateTaskTitleChangeKeepsTheFilenameByDesign() async throws {
        let model = try await makeConfiguredModel()
        let original = try XCTUnwrap(model.tasks.first { $0.id == Self.planQ4ID })
        var updated = original
        updated.title = "Brand new title"

        _ = try await model.updateTask(updated)

        // The file keeps its name (#7: update never re-derives the filename
        // from the title; re-slugging is the separate rename API).
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: taskFile("Plan Q4 roadmap.md").path(percentEncoded: false)))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: taskFile("Brand new title.md").path(percentEncoded: false)))
        let parsed = try parsedTask("Plan Q4 roadmap.md")
        XCTAssertEqual(parsed.title, "Brand new title")
        XCTAssertTrue(model.tasks.contains { $0.title == "Brand new title" })
        XCTAssertFalse(model.tasks.contains { $0.title == "Plan Q4 roadmap" },
                       "only the display title changed")
        XCTAssertEqual(model.tasks.count, 3)
    }

    func testUpdateTaskKeepsBodyAndSubtasksIntact() async throws {
        let model = try await makeConfiguredModel()
        let original = try XCTUnwrap(model.tasks.first { $0.id == Self.planQ4ID })
        var updated = original
        updated.status = .blocked

        _ = try await model.updateTask(updated)

        let parsed = try parsedTask("Plan Q4 roadmap.md")
        XCTAssertEqual(parsed.status, .blocked)
        XCTAssertEqual(parsed.subtasks.count, 2, "the subtask tree persists through the update")
        XCTAssertEqual(
            parsed.subtasks.last?.children.count, 2, "nesting survives the rewrite")
        XCTAssertTrue(
            try text(at: taskFile("Plan Q4 roadmap.md"))
                .contains("Draft the Q4 roadmap covering hiring"),
            "the Markdown body is re-attached byte-for-byte (nothing silently lost)")
    }

    func testUpdateTaskWithUnknownIDThrowsTypedAndChangesNothing() async throws {
        let model = try await makeConfiguredModel()
        let unknown = try TaskItem(
            id: UUID(), title: "Ghost", categories: [Category(name: "Inbox")])

        do {
            _ = try await model.updateTask(unknown)
            XCTFail("expected unknownTaskID")
        } catch let error as VaultStoreError {
            XCTAssertEqual(error, .unknownTaskID(unknown.id))
        }
        XCTAssertEqual(model.tasks.count, 3, "nothing was written")
    }

    func testUpdateTaskWithoutConfiguredVaultThrowsNoVaultConfigured() async throws {
        let model = AppModel(settings: settings)
        await model.bootstrap()

        do {
            _ = try await model.updateTask(try makeNewTask())
            XCTFail("expected noVaultConfigured")
        } catch let error as AppModel.TaskWriteError {
            XCTAssertEqual(error, .noVaultConfigured)
        }
    }

    // MARK: - Project field wiring (issue #16 regression: picker → saved task → disk)

    /// The form's save path (issue #16): `original` pre-fills the state in
    /// edit mode (`TaskFormState(task:)`, as the view does), `configure`
    /// fills the rest, then `save()`'s steps — commit the pending draft,
    /// apply the picker's choice (`applyProjectChoice`, as the view does
    /// live and at save time), `makeTask(preserving:)` — build the task the
    /// passthrough persists.
    private func makeFormTask(
        prefilling original: TaskItem? = nil,
        _ configure: (inout TaskFormState) -> Void,
        projectChoice: TaskFormState.ProjectChoice = .none,
        newProjectName: String = ""
    ) throws -> TaskItem {
        var state = original.map(TaskFormState.init(task:)) ?? TaskFormState()
        configure(&state)
        state.commitWholeDraft()
        state.applyProjectChoice(projectChoice, newProjectName: newProjectName)
        return try state.makeTask(preserving: original)
    }

    func testCreateWithExistingProjectSelectedSavesItToDisk() async throws {
        // (a) create mode: the picker's existing-project choice lands in the
        // saved task (regression: it used to be silently dropped).
        let model = try await makeConfiguredModel()
        let task = try makeFormTask(
            { state in
                state.title = "Ship release notes"
                state.commitCategory("Writing")
            },
            projectChoice: .existing("Writing"))

        _ = try await model.createTask(task)

        let parsed = try parsedTask("Ship release notes.md")
        XCTAssertEqual(parsed.title, "Ship release notes")
        XCTAssertEqual(parsed.project?.name, "Writing")
    }

    func testCreateWithNewFreeTextProjectSavesItToDisk() async throws {
        // (b) create mode: a typed new-project name lands in the saved task.
        let model = try await makeConfiguredModel()
        let task = try makeFormTask(
            { state in
                state.title = "Audit subscriptions"
                state.commitCategory("Admin")
            },
            projectChoice: .new,
            newProjectName: "Life Admin")

        _ = try await model.createTask(task)

        let parsed = try parsedTask("Audit subscriptions.md")
        XCTAssertEqual(parsed.project?.name, "Life Admin")
    }

    func testEditProjectToNoneClearsItOnDisk() async throws {
        // (c) edit mode: changing the project to None clears it — nil on
        // disk, not an empty string (regression: the stale project
        // persisted regardless of the picker).
        let model = try await makeConfiguredModel()
        let original = try XCTUnwrap(model.tasks.first { $0.id == Self.planQ4ID })
        XCTAssertEqual(original.project?.name, "Work", "precondition: the fixture task has a project")
        let updated = try makeFormTask(
            prefilling: original, { _ in },
            projectChoice: .none)

        _ = try await model.updateTask(updated)

        let parsed = try parsedTask("Plan Q4 roadmap.md")
        XCTAssertNil(parsed.project, "None clears the project (nil, never an empty string)")
        XCTAssertEqual(parsed.title, "Plan Q4 roadmap")
    }

    func testEditProjectAToBSavesBOnDisk() async throws {
        // (d) edit mode: changing project A → B saves B (regression: the
        // pre-filled project persisted regardless of the picker).
        let model = try await makeConfiguredModel()
        let original = try XCTUnwrap(model.tasks.first { $0.id == Self.planQ4ID })
        let updated = try makeFormTask(
            prefilling: original, { _ in },
            projectChoice: .existing("Personal"))

        _ = try await model.updateTask(updated)

        let parsed = try parsedTask("Plan Q4 roadmap.md")
        XCTAssertEqual(parsed.project?.name, "Personal")
        XCTAssertNotEqual(parsed.project?.name, "Work")
    }
}
