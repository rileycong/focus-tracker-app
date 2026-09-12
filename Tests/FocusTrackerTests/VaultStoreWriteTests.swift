import XCTest
@testable import FocusTracker

/// Write-side tests for `VaultStore` (issue #7). Every vault-using test copies
/// `fixtures/sample-vault/` into a fresh temp directory — the repo fixture is
/// never touched (same convention as the #6 read-side tests).
final class VaultStoreWriteTests: XCTestCase {

    // MARK: - Fixture access

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
            .appendingPathComponent("VaultStoreWriteTests-\(UUID().uuidString)", isDirectory: true)
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

    private func bytes(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func text(at url: URL) throws -> String {
        try String(decoding: bytes(at: url), as: UTF8.self)
    }

    private func makeTask(
        id: UUID = UUID(), title: String, status: TaskStatus = .toDo
    ) throws -> TaskItem {
        try TaskItem(
            id: id, title: title, categories: [Category(name: "Testing")], status: status)
    }

    private func body(of url: URL) throws -> String {
        try FrontmatterCodec.split(text(at: url)).body
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

    /// Replaces the fixture's "Read Deep Work.md" with different valid content
    /// (same ID) — the external edit the staleness guard must catch.
    private func externallyRewriteReadDeepWork(status: TaskStatus, body: String) throws {
        let fileText = """
        ---
        id: \(Self.readDeepWorkID.uuidString)
        title: Read Deep Work
        status: \(status.rawValue)
        categories:
          - Learning
        ---
        \(body)
        """
        try fileText.write(to: taskFile("Read Deep Work.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - Create

    func testCreateWritesFileAtSlugParsesBackEqualAndPersistsAssignedUUID() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        let deadline = try XCTUnwrap(DeadlineDay.date(from: "2026-12-01"))
        let grandchild = SubtaskItem(id: UUID(), title: "Outline the sections", status: .toDo)
        let subtask = SubtaskItem(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Draft outline", status: .inProgress, priority: .low, effort: .s,
            deadline: deadline, notes: "First pass",
            children: [grandchild])
        let task = try TaskItem(
            title: "Write issue seven",
            categories: [Category(name: "Planning"), Category(name: "Writing")],
            status: .inProgress,
            project: Project(name: "Focus Tracker"),
            priority: .high,
            effort: .m,
            deadline: deadline,
            notes: "Implement the write side.",
            subtasks: [subtask])

        let created = try await store.create(task)

        let fileURL = taskFile("Write issue seven.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "the file exists at the expected slug")
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: fileURL)), created,
                       "the file parses back equal to the created task")
        XCTAssertEqual(created.id, task.id, "the store uses the ID the model carries")
        let parsedID = try FrontmatterCodec.parseTask(text(at: fileURL)).id
        XCTAssertEqual(parsedID, created.id, "the assigned UUID is persisted in the file's id")
        XCTAssertEqual(try body(of: fileURL), "", "new files start with an empty body")
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 4)
    }

    func testCreateUsesTheIDTheModelCarriesWhenTheCallerSetsOne() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let fixedID = UUID(uuidString: "eeeeeeee-1111-4222-8333-444444444444")!

        let created = try await store.create(try makeTask(id: fixedID, title: "Fixed ID task"))

        XCTAssertEqual(created.id, fixedID)
        XCTAssertEqual(try FrontmatterCodec.parseTask(
            text(at: taskFile("Fixed ID task.md"))).id, fixedID)
    }

    func testSlugRuleFollowsThePinnedTitleToFilenameRule() {
        XCTAssertEqual(
            VaultStore.slug(from: "Read Deep Work"), "Read Deep Work.md",
            "case and spaces preserved")
        XCTAssertEqual(
            VaultStore.slug(from: "Fix: a/b path"), "Fix- a-b path.md",
            "/ and : replaced with -")
        XCTAssertEqual(
            VaultStore.slug(from: "line\nbreak"), "line-break.md",
            "control characters replaced with -")
        XCTAssertEqual(
            VaultStore.slug(from: "trailing... "), "trailing.md",
            "trailing dots and spaces trimmed")
        XCTAssertEqual(VaultStore.slug(from: "..."), "untitled.md")
        XCTAssertEqual(
            VaultStore.slug(from: "   "), "untitled.md",
            "a title that sanitizes to empty becomes untitled")
        XCTAssertEqual(
            VaultStore.slug(from: "Read Deep Work"), VaultStore.slug(from: "Read Deep Work"),
            "deterministic: same title, same slug")
    }

    func testCreateCollisionProbesSuffixedNamesOnDiskAndLeavesExistingFilesUntouched()
        async throws
    {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let originalURL = taskFile("Read Deep Work.md")
        let originalBytes = try bytes(at: originalURL)

        let first = try await store.create(try makeTask(title: "Read Deep Work"))

        let firstURL = taskFile("Read Deep Work-2.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path),
                      "title.md taken → title-2.md created")
        XCTAssertEqual(try bytes(at: originalURL), originalBytes, "original file untouched")
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: firstURL)).id, first.id)

        // An externally created file the store never loaded counts in the
        // probe too (pinned: real on-disk existence).
        try "externally created".write(
            to: taskFile("Renew passport-2.md"), atomically: true, encoding: .utf8)
        let renewBytes = try bytes(at: taskFile("Renew passport.md"))
        let externalBytes = try bytes(at: taskFile("Renew passport-2.md"))

        _ = try await store.create(try makeTask(title: "Renew passport"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: taskFile("Renew passport-3.md").path),
                      "the probe skips the externally created -2 file")
        XCTAssertEqual(try bytes(at: taskFile("Renew passport.md")), renewBytes)
        XCTAssertEqual(try bytes(at: taskFile("Renew passport-2.md")), externalBytes)
    }

    func testCreateWithAlreadyLoadedIDThrowsDuplicateTaskIDOnCreate() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let duplicate = try TaskItem(
            id: Self.planQ4ID, title: "Another plan", categories: [Category(name: "Planning")])

        await expectStoreError(.duplicateTaskIDOnCreate(Self.planQ4ID)) {
            try await store.create(duplicate)
        }
        let fileCount = try FileManager.default.contentsOfDirectory(
            atPath: tasksDirectory.path(percentEncoded: false)).count
        XCTAssertEqual(fileCount, 3, "nothing is written")
    }

    // MARK: - Update

    func testUpdatePersistsChangesPreservesBodyByteForByteAndLeavesOtherFilesUntouched()
        async throws
    {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        var plan = try await loadedTask(Self.planQ4ID, from: store)

        let planURL = taskFile("Plan Q4 roadmap.md")
        let before = try bytes(at: planURL)
        let deepWorkBytes = try bytes(at: taskFile("Read Deep Work.md"))
        let renewBytes = try bytes(at: taskFile("Renew passport.md"))

        plan.status = .blocked
        plan.deadline = try XCTUnwrap(DeadlineDay.date(from: "2026-11-30"))
        plan.subtasks.append(SubtaskItem(title: "Book the offsite", status: .toDo))

        let updated = try await store.update(plan)

        let after = try bytes(at: planURL)
        XCTAssertNotEqual(after, before, "the changed fields persist on disk")
        XCTAssertEqual(try FrontmatterCodec.split(String(decoding: before, as: UTF8.self)).body,
                       try FrontmatterCodec.split(String(decoding: after, as: UTF8.self)).body,
                       "the body is re-attached byte-for-byte")
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: planURL)), updated,
                       "the whole task, nested subtasks included, round-trips")
        XCTAssertEqual(try bytes(at: taskFile("Read Deep Work.md")), deepWorkBytes,
                       "other files untouched")
        XCTAssertEqual(try bytes(at: taskFile("Renew passport.md")), renewBytes,
                       "other files untouched")
    }

    func testUpdateKeepsTheExistingFilenameEvenWhenTheTitleChanged() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        var read = try await loadedTask(Self.readDeepWorkID, from: store)

        read.title = "Read Deep Work II"
        _ = try await store.update(read)

        XCTAssertTrue(FileManager.default.fileExists(atPath: taskFile("Read Deep Work.md").path),
                      "update deliberately does not re-derive the filename — rename's job")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: taskFile("Read Deep Work II.md").path))
        XCTAssertEqual(try FrontmatterCodec.parseTask(
            text(at: taskFile("Read Deep Work.md"))).title, "Read Deep Work II")
        guard case .task(let looked) = await store.lookup(Self.readDeepWorkID) else {
            return XCTFail("lookup must reflect the update")
        }
        XCTAssertEqual(looked.title, "Read Deep Work II")
    }

    // MARK: - Rename

    func testRenameMovesFileKeepsIDAndParsesBackNewTitle() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let renew = try await loadedTask(Self.renewPassportID, from: store)

        let oldURL = taskFile("Renew passport.md")
        let oldBody = try body(of: oldURL)

        let renamed = try await store.rename(renew, to: "A first task")

        XCTAssertEqual(renamed.id, Self.renewPassportID, "the ID is unchanged (rename-safe)")
        XCTAssertEqual(renamed.title, "A first task")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path), "old filename gone")
        let newURL = taskFile("A first task.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path), "new filename exists")
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: newURL)).id, Self.renewPassportID)
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: newURL)).title, "A first task")
        XCTAssertEqual(try body(of: newURL), oldBody, "the body survives the move")

        // The mapping is updated: a subsequent update writes the *new* file.
        var bumped = renamed
        bumped.status = .done
        _ = try await store.update(bumped)
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: newURL)).status, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))

        // The inventory shows the new title at the new filename-sorted position.
        let tasks = await store.tasks
        XCTAssertEqual(tasks.map(\.title), ["A first task", "Plan Q4 roadmap", "Read Deep Work"])
        guard case .task = await store.lookup(Self.renewPassportID) else {
            return XCTFail("the ID must still resolve after the rename")
        }
    }

    func testRenameCollisionWithDifferentFileFailsTypedAndTouchesNothing() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let plan = try await loadedTask(Self.planQ4ID, from: store)
        let renew = try await loadedTask(Self.renewPassportID, from: store)

        let planURL = taskFile("Plan Q4 roadmap.md")
        let deepURL = taskFile("Read Deep Work.md")
        let planBytes = try bytes(at: planURL)
        let deepBytes = try bytes(at: deepURL)

        await expectStoreError(.renameDestinationExists("Read Deep Work.md")) {
            try await store.rename(plan, to: "Read Deep Work")
        }
        XCTAssertEqual(try bytes(at: planURL), planBytes, "both files untouched")
        XCTAssertEqual(try bytes(at: deepURL), deepBytes, "both files untouched")

        // An externally created destination (never loaded) collides too.
        try "external".write(to: taskFile("External note.md"), atomically: true, encoding: .utf8)
        let renewBytes = try bytes(at: taskFile("Renew passport.md"))
        let externalBytes = try bytes(at: taskFile("External note.md"))
        await expectStoreError(.renameDestinationExists("External note.md")) {
            try await store.rename(renew, to: "External note")
        }
        XCTAssertEqual(try bytes(at: taskFile("Renew passport.md")), renewBytes,
                       "source file untouched")
        XCTAssertEqual(try bytes(at: taskFile("External note.md")), externalBytes,
                       "destination file untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: taskFile("A first task.md").path))
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 3, "inventory untouched")
    }

    func testRenameToSameSlugSkipsTheMoveAndStillPersistsNewTitle() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let read = try await loadedTask(Self.readDeepWorkID, from: store)

        // Trailing dots sanitize to the same slug ("Read Deep Work.md").
        let renamed = try await store.rename(read, to: "Read Deep Work...")

        XCTAssertEqual(renamed.id, Self.readDeepWorkID)
        let url = taskFile("Read Deep Work.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "no move — same file")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: taskFile("Read Deep Work....md").path))
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: url)).title, "Read Deep Work...",
                       "the new title is persisted")
        let tasks = await store.tasks
        XCTAssertEqual(tasks.first { $0.id == Self.readDeepWorkID }?.title, "Read Deep Work...")
    }

    // MARK: - Delete

    func testDeleteRemovesFileMappingAndInventoryEntry() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let read = try await loadedTask(Self.readDeepWorkID, from: store)

        try await store.delete(read)

        XCTAssertFalse(FileManager.default.fileExists(atPath: taskFile("Read Deep Work.md").path),
                       "file gone")
        let tasks = await store.tasks
        XCTAssertEqual(tasks.map(\.title), ["Plan Q4 roadmap", "Renew passport"],
                       "inventory shrunk")
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 2)
        guard case .notFound = await store.lookup(Self.readDeepWorkID) else {
            return XCTFail("mapping entry gone")
        }

        // The deleted ID is now stale: write ops fail typed.
        await expectStoreError(.unknownTaskID(Self.readDeepWorkID)) {
            try await store.update(read)
        }
        await expectStoreError(.unknownTaskID(Self.readDeepWorkID)) {
            try await store.delete(read)
        }
    }

    // MARK: - Unknown / stale IDs

    func testUnknownIDFailsTypedOnEveryWriteOperation() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let ghost = UUID()
        let ghostTask = try makeTask(id: ghost, title: "Ghost")

        await expectStoreError(.unknownTaskID(ghost)) { try await store.update(ghostTask) }
        await expectStoreError(.unknownTaskID(ghost)) {
            try await store.rename(ghostTask, to: "Ghost")
        }
        await expectStoreError(.unknownTaskID(ghost)) { try await store.delete(ghostTask) }
        await expectStoreError(.unknownTaskID(ghost)) { try await store.setStatus(ghost, to: .done) }

        // An ID that only resolves to a subtask is not a top-level task.
        await expectStoreError(.notTopLevelTask(Self.collectInputID)) {
            try await store.setStatus(Self.collectInputID, to: .done)
        }
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 3, "nothing changed")
    }

    // MARK: - Staleness guard

    func testStalenessGuardBlocksUpdateRenameAndDeleteWithoutClobbering() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        var read = try await loadedTask(Self.readDeepWorkID, from: store)

        try externallyRewriteReadDeepWork(status: .done, body: "\nExternally edited body.\n")
        let externalURL = taskFile("Read Deep Work.md")
        let externalBytes = try bytes(at: externalURL)

        read.status = .blocked
        let conflict = VaultStoreError.vaultChangedExternally(
            id: Self.readDeepWorkID, fileName: "Read Deep Work.md")
        await expectStoreError(conflict) { try await store.update(read) }
        await expectStoreError(conflict) { try await store.rename(read, to: "Deep Work notes") }
        await expectStoreError(conflict) { try await store.delete(read) }

        XCTAssertEqual(try bytes(at: externalURL), externalBytes, "nothing clobbered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: taskFile("Deep Work notes.md").path))
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 3, "inventory untouched")

        // An externally *deleted* file is the same typed conflict.
        try FileManager.default.removeItem(at: externalURL)
        await expectStoreError(conflict) { try await store.update(read) }
    }

    func testReloadResolvesStalenessAndRetriedOperationsSucceed() async throws {
        let store = makeStore()

        // Update after reload.
        try externallyRewriteReadDeepWork(status: .done, body: "\nFresh external notes.\n")
        _ = try requireLoaded(await store.load())
        var read = try await loadedTask(Self.readDeepWorkID, from: store)
        read.status = .blocked
        _ = try await store.update(read)
        var reloaded = try text(at: taskFile("Read Deep Work.md"))
        XCTAssertEqual(try FrontmatterCodec.parseTask(reloaded).status, .blocked)
        XCTAssertEqual(try FrontmatterCodec.split(reloaded).body, "\nFresh external notes.\n",
                       "the body record follows the reload")

        // Rename after reload.
        try externallyRewriteReadDeepWork(status: .dropped, body: "\nEdited again.\n")
        _ = try requireLoaded(await store.load())
        read = try await loadedTask(Self.readDeepWorkID, from: store)
        _ = try await store.rename(read, to: "Deep Work notes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: taskFile("Read Deep Work.md").path))
        reloaded = try text(at: taskFile("Deep Work notes.md"))
        XCTAssertEqual(try FrontmatterCodec.parseTask(reloaded).title, "Deep Work notes")
        XCTAssertEqual(try FrontmatterCodec.split(reloaded).body, "\nEdited again.\n")

        // Delete after reload.
        try externallyRewriteReadDeepWork(status: .dropped, body: "\nOne more edit.\n")
        _ = try requireLoaded(await store.load())
        read = try await loadedTask(Self.readDeepWorkID, from: store)
        try await store.delete(read)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: taskFile("Deep Work notes.md").path))
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 2)
    }

    // MARK: - Missing vault / Tasks directory

    func testWriteOpsSurfaceTypedErrorsWhenVaultOrTasksDirectoryMissing() async throws {
        // Vault missing entirely: create surfaces the writer's typed error.
        let missingVault = root.appendingPathComponent("no-such-vault", isDirectory: true)
        let absentStore = makeStore(for: missingVault)
        let missingTasksPath = missingVault
            .appendingPathComponent("Tasks", isDirectory: true)
            .path(percentEncoded: false)
        await expectStoreError(.writeFailed(.directoryMissing(path: missingTasksPath))) {
            try await absentStore.create(try makeTask(title: "New task"))
        }

        // Load the fixture, then remove the vault: the loaded mapping survives,
        // so every write op reports the missing directory (before any staleness
        // re-read could misreport it as an external change).
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let read = try await loadedTask(Self.readDeepWorkID, from: store)
        try FileManager.default.removeItem(at: vaultURL)

        let tasksPath = tasksDirectory.path(percentEncoded: false)
        let missingDirectory = VaultStoreError.writeFailed(.directoryMissing(path: tasksPath))
        await expectStoreError(missingDirectory) {
            try await store.create(try makeTask(title: "New task"))
        }
        await expectStoreError(missingDirectory) { try await store.update(read) }
        await expectStoreError(missingDirectory) { try await store.rename(read, to: "Elsewhere") }
        await expectStoreError(missingDirectory) { try await store.delete(read) }
        await expectStoreError(missingDirectory) {
            try await store.setStatus(Self.readDeepWorkID, to: .done)
        }

        // Vault present, Tasks/ missing: the same typed writer error.
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        await expectStoreError(missingDirectory) {
            try await store.create(try makeTask(title: "New task"))
        }
        await expectStoreError(missingDirectory) { try await store.delete(read) }
    }

    // MARK: - Inventory consistency after each write operation

    func testInventoryStaysConsistentWithDiskAfterEachWriteOperation() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())

        // Create.
        let created = try await store.create(try makeTask(title: "Fresh idea"))
        var inMemory = await store.tasks
        var onDisk = try await diskTasks()
        XCTAssertEqual(inMemory, onDisk)
        var taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 4)
        guard case .task(let looked) = await store.lookup(created.id), looked == created else {
            return XCTFail("lookup must resolve the created task")
        }

        // Update (replaces in place).
        var read = try XCTUnwrap(inMemory.first { $0.id == Self.readDeepWorkID })
        read.status = .inProgress
        _ = try await store.update(read)
        inMemory = await store.tasks
        onDisk = try await diskTasks()
        XCTAssertEqual(inMemory, onDisk)
        taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 4)
        guard case .task(let updatedLooked) = await store.lookup(read.id) else {
            return XCTFail("lookup must resolve the updated task")
        }
        XCTAssertEqual(updatedLooked.status, .inProgress)

        // Rename (repositions the inventory entry).
        let plan = try XCTUnwrap(inMemory.first { $0.id == Self.planQ4ID })
        let renamed = try await store.rename(plan, to: "AAA rename target")
        inMemory = await store.tasks
        onDisk = try await diskTasks()
        XCTAssertEqual(inMemory, onDisk)
        XCTAssertEqual(inMemory.first?.id, renamed.id, "moved to the sorted front")

        // Delete.
        try await store.delete(renamed)
        inMemory = await store.tasks
        onDisk = try await diskTasks()
        XCTAssertEqual(inMemory, onDisk)
        taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 3)
        guard case .notFound = await store.lookup(renamed.id) else {
            return XCTFail("the deleted task must not resolve")
        }

        // lastLoadState/warnings still describe the last load (documented).
        let lastState = await store.lastLoadState
        guard case .loaded(let loadedInventory)? = lastState else {
            return XCTFail("lastLoadState must still describe the last load")
        }
        XCTAssertEqual(loadedInventory.tasks.count, 3, "the load's own snapshot, not the writes")
        let warnings = await store.warnings
        XCTAssertTrue(warnings.isEmpty)
    }

    // MARK: - setStatus write-through

    func testSetStatusWritesThroughImmediatelyForTopLevelTasksOnly() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let planURL = taskFile("Plan Q4 roadmap.md")
        let bodyBefore = try body(of: planURL)

        let returned = try await store.setStatus(Self.planQ4ID, to: .done)

        XCTAssertEqual(returned.status, .done)
        XCTAssertEqual(try FrontmatterCodec.parseTask(text(at: planURL)).status, .done,
                       "written through to disk immediately")
        XCTAssertEqual(
            try FrontmatterCodec.parseTask(text(at: planURL)).subtasks.map(\.status),
            [.done, .inProgress],
            "the status is written exactly as given — no propagation to subtasks")
        XCTAssertEqual(try body(of: planURL), bodyBefore, "body preserved")
        guard case .task(let looked) = await store.lookup(Self.planQ4ID) else {
            return XCTFail("lookup must reflect the status change")
        }
        XCTAssertEqual(looked.status, .done)

        await expectStoreError(.notTopLevelTask(Self.collectInputID)) {
            try await store.setStatus(Self.collectInputID, to: .done)
        }
    }
}
