import XCTest
@testable import FocusTracker

final class VaultStoreTests: XCTestCase {

    // MARK: - Fixture access (the repo fixture is copied to a temp dir, never touched)

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private static let planQ4ID = UUID(uuidString: "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02")!
    private static let collectInputID = UUID(uuidString: "8a4c2e6f-1d3b-4f5a-8b9c-2e7d1a4c6e08")!
    private static let draftOKRID = UUID(uuidString: "5d9e7f2a-3c6b-4a1d-9e8f-6b2c4d7a9e13")!
    private static let defineObjectivesID = UUID(uuidString: "1b6d8f3a-4e7c-4b2a-8d5e-9f3b1c6d8e24")!
    private static let mapKeyResultsID = UUID(uuidString: "7c3e9a4b-5f8d-4c3b-9e6f-1a4c2d8e9f35")!
    private static let readDeepWorkID = UUID(uuidString: "c9d1e3f5-2a4b-4c6d-8e0f-7b9a1d3c5e69")!
    private static let renewPassportID = UUID(uuidString: "a2b8c4d6-9e1f-4a7b-b3c5-8d2e6f4a1c47")!

    private var root: URL!
    private var vaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VaultStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    private func writeTaskFile(
        _ name: String, id: UUID, title: String, in directory: URL? = nil
    ) throws {
        let text = """
        ---
        id: \(id.uuidString)
        title: \(title)
        status: To Do
        categories:
          - Testing
        ---

        Body of \(title).
        """
        try text.write(
            to: (directory ?? tasksDirectory).appendingPathComponent(name),
            atomically: true,
            encoding: .utf8)
    }

    // MARK: - Happy path

    func testHappyPathLoadsAllFixtureTasksAndNestedTree() async throws {
        let store = makeStore()
        let inventory = try requireLoaded(await store.load())

        XCTAssertTrue(inventory.warnings.isEmpty)
        XCTAssertEqual(
            inventory.tasks.map(\.title),
            ["Plan Q4 roadmap", "Read Deep Work", "Renew passport"],
            "tasks come back in filename-sorted order")

        let tasks = await store.tasks
        XCTAssertEqual(tasks.map(\.title), ["Plan Q4 roadmap", "Read Deep Work", "Renew passport"])
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 3)

        let plan = try XCTUnwrap(tasks.first { $0.id == Self.planQ4ID })
        XCTAssertEqual(
            plan.subtasks.map(\.title), ["Collect team input", "Draft objectives and key results"])
        let draft = try XCTUnwrap(plan.subtasks.first { $0.id == Self.draftOKRID })
        XCTAssertEqual(
            draft.children.map(\.title), ["Define Q4 objectives", "Map key results to objectives"])

        let allFixtureIDs: [UUID] = [
            Self.planQ4ID, Self.readDeepWorkID, Self.renewPassportID,
            Self.collectInputID, Self.draftOKRID, Self.defineObjectivesID, Self.mapKeyResultsID,
        ]
        for id in allFixtureIDs {
            let result = await store.lookup(id)
            if case .notFound = result {
                XCTFail("fixture ID \(id.uuidString) must be resolvable")
            }
        }
    }

    // MARK: - Lookup

    func testLookupByNestedSubtaskIDReturnsSubtaskWithinParentTree() async throws {
        let store = makeStore()
        _ = await store.load()

        guard case .subtask(let grandchild, let parent) = await store.lookup(Self.defineObjectivesID)
        else {
            return XCTFail("expected .subtask for grandchild ID \(Self.defineObjectivesID)")
        }
        XCTAssertEqual(grandchild.id, Self.defineObjectivesID)
        XCTAssertEqual(grandchild.title, "Define Q4 objectives")
        XCTAssertEqual(parent.id, Self.planQ4ID)
        XCTAssertEqual(parent.title, "Plan Q4 roadmap")

        guard case .subtask(let levelOne, let parentAgain) = await store.lookup(Self.collectInputID)
        else {
            return XCTFail("expected .subtask for level-1 subtask ID \(Self.collectInputID)")
        }
        XCTAssertEqual(levelOne.title, "Collect team input")
        XCTAssertEqual(parentAgain.id, Self.planQ4ID)
    }

    func testLookupUnknownIDReturnsNotFoundBeforeAndAfterLoad() async throws {
        let store = makeStore()
        guard case .notFound = await store.lookup(UUID()) else {
            return XCTFail("lookup before any load must be .notFound")
        }
        guard case .notFound = await store.lookup(Self.planQ4ID) else {
            return XCTFail("lookup on an unloaded store must not accidentally match")
        }

        _ = await store.load()
        guard case .notFound = await store.lookup(UUID()) else {
            return XCTFail("lookup of an unknown ID must be .notFound")
        }
    }

    // MARK: - Malformed files

    func testMalformedFilesAreSkippedWithWarningsAndOthersStillLoad() async throws {
        let brokenName = "Broken task.md"
        try "this file has no frontmatter delimiters\n".write(
            to: tasksDirectory.appendingPathComponent(brokenName),
            atomically: true, encoding: .utf8)
        let unterminatedName = "Unterminated.md"
        try "---\nid: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02\n".write(
            to: tasksDirectory.appendingPathComponent(unterminatedName),
            atomically: true, encoding: .utf8)

        let store = makeStore()
        let inventory = try requireLoaded(await store.load())

        XCTAssertEqual(inventory.tasks.count, 3, "the three healthy tasks still load")
        XCTAssertEqual(inventory.warnings.count, 2)
        XCTAssertEqual(inventory.warnings.map(\.fileName), [brokenName, unterminatedName])
        XCTAssertEqual(
            inventory.warnings[0].underlyingError as? FrontmatterError,
            .missingOpeningDelimiter)
        XCTAssertEqual(
            inventory.warnings[1].underlyingError as? FrontmatterError,
            .missingClosingDelimiter)

        let warnings = await store.warnings
        XCTAssertEqual(warnings.map(\.fileName), [brokenName, unterminatedName])
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 3)
    }

    // MARK: - Missing vault states

    func testVaultPathMissingYieldsVaultMissingStateWithoutCrashing() async throws {
        let missingVault = root.appendingPathComponent("no-such-vault", isDirectory: true)
        let store = makeStore(for: missingVault)

        let state = await store.load()
        guard case .vaultMissing(let path) = state else {
            return XCTFail("expected .vaultMissing, got \(state)")
        }
        XCTAssertEqual(path, missingVault)
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 0)
        let warnings = await store.warnings
        XCTAssertEqual(warnings.count, 0)
        guard case .notFound = await store.lookup(Self.planQ4ID) else {
            return XCTFail("nothing can resolve from a missing vault")
        }
    }

    func testTasksDirectoryMissingYieldsTasksDirectoryMissingState() async throws {
        try FileManager.default.removeItem(at: tasksDirectory)
        let store = makeStore()

        let state = await store.load()
        guard case .tasksDirectoryMissing(let path) = state else {
            return XCTFail("expected .tasksDirectoryMissing, got \(state)")
        }
        XCTAssertEqual(path, vaultURL)
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 0)
        let warnings = await store.warnings
        XCTAssertEqual(warnings.count, 0)
    }

    // MARK: - Empty-but-valid vault

    func testEmptyButValidVaultLoadsZeroTasksWithNoWarnings() async throws {
        for name in try FileManager.default.contentsOfDirectory(
            atPath: tasksDirectory.path(percentEncoded: false))
        {
            try FileManager.default.removeItem(at: tasksDirectory.appendingPathComponent(name))
        }

        let store = makeStore()
        let inventory = try requireLoaded(await store.load())

        XCTAssertTrue(inventory.tasks.isEmpty)
        XCTAssertTrue(inventory.warnings.isEmpty, "an empty vault must be warning-free")
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 0)
        let tasks = await store.tasks
        XCTAssertEqual(tasks.count, 0)
    }

    // MARK: - Non-task entries

    func testNonMarkdownFilesAreIgnoredSilently() async throws {
        try "not a task".write(
            to: tasksDirectory.appendingPathComponent("notes.txt"),
            atomically: true, encoding: .utf8)
        try "readme".write(
            to: tasksDirectory.appendingPathComponent("README"),
            atomically: true, encoding: .utf8)
        try "junk".write(
            to: tasksDirectory.appendingPathComponent(".DS_Store"),
            atomically: true, encoding: .utf8)

        let store = makeStore()
        let inventory = try requireLoaded(await store.load())

        XCTAssertEqual(inventory.tasks.count, 3)
        XCTAssertTrue(inventory.warnings.isEmpty)
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 3)
    }

    func testMarkdownExtensionIsMatchedCaseInsensitively() async throws {
        let newID = UUID()
        try writeTaskFile("UPPER CASE.MD", id: newID, title: "Upper case")

        let store = makeStore()
        let inventory = try requireLoaded(await store.load())

        XCTAssertEqual(inventory.tasks.count, 4)
        XCTAssertTrue(inventory.warnings.isEmpty)
        guard case .task = await store.lookup(newID) else {
            return XCTFail("an .MD file must load")
        }
    }

    func testSubdirectoryInsideTasksIsIgnoredWithWarning() async throws {
        let archive = tasksDirectory.appendingPathComponent("Old archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try writeTaskFile("Nested task.md", id: UUID(), title: "Nested in subdirectory", in: archive)

        let store = makeStore()
        let inventory = try requireLoaded(await store.load())

        XCTAssertEqual(inventory.tasks.count, 3, "subdirectory contents are not read")
        XCTAssertEqual(inventory.warnings.count, 1)
        let warning = try XCTUnwrap(inventory.warnings.first)
        XCTAssertEqual(warning.fileName, "Old archive")
        XCTAssertEqual(
            warning.underlyingError as? VaultStoreError,
            .subdirectoryIgnored("Old archive"))
    }

    // MARK: - Duplicate task IDs

    func testDuplicateTaskIDPrefersFilenameSortedFirstFileAndWarnsOnBothFiles() async throws {
        let duplicateID = UUID()
        let duplicateVault = root.appendingPathComponent("duplicates", isDirectory: true)
        let duplicateTasks = duplicateVault.appendingPathComponent("Tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateTasks, withIntermediateDirectories: true)
        try writeTaskFile(
            "A duplicate.md", id: duplicateID, title: "First file wins", in: duplicateTasks)
        try writeTaskFile(
            "B duplicate.md", id: duplicateID, title: "Second file skipped", in: duplicateTasks)

        let store = makeStore(for: duplicateVault)
        let inventory = try requireLoaded(await store.load())

        XCTAssertEqual(inventory.tasks.count, 1, "the duplicate pair contributes one task")
        XCTAssertEqual(inventory.tasks.first?.title, "First file wins")
        XCTAssertEqual(inventory.warnings.count, 1)
        let warning = try XCTUnwrap(inventory.warnings.first)
        XCTAssertEqual(warning.fileName, "B duplicate.md")
        XCTAssertEqual(
            warning.underlyingError as? VaultStoreError,
            .duplicateTaskID(id: duplicateID, firstFile: "A duplicate.md"))
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 1)
    }

    // MARK: - Reload freshness

    func testReloadPicksUpExternalChangesAndReplacesWarnings() async throws {
        let brokenName = "Broken.md"
        try "no delimiters".write(
            to: tasksDirectory.appendingPathComponent(brokenName),
            atomically: true, encoding: .utf8)

        let store = makeStore()
        let first = try requireLoaded(await store.load())
        XCTAssertEqual(first.tasks.count, 3)
        XCTAssertEqual(first.warnings.map(\.fileName), [brokenName])

        try FileManager.default.removeItem(at: tasksDirectory.appendingPathComponent(brokenName))
        let newID = UUID()
        try writeTaskFile("New task.md", id: newID, title: "Added externally")

        let second = try requireLoaded(await store.load())
        XCTAssertEqual(second.tasks.count, 4, "reload must re-read from disk")
        XCTAssertTrue(second.warnings.isEmpty, "reload must replace the previous warning set")
        guard case .task = await store.lookup(newID) else {
            return XCTFail("externally added task must resolve after reload")
        }
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 4)
        let warnings = await store.warnings
        XCTAssertEqual(warnings.count, 0)
    }

    func testReloadAfterVaultDisappearanceClearsInventory() async throws {
        let store = makeStore()
        _ = try requireLoaded(await store.load())
        let initialCount = await store.taskCount
        XCTAssertEqual(initialCount, 3)

        try FileManager.default.removeItem(at: vaultURL)
        let state = await store.load()
        guard case .vaultMissing = state else {
            return XCTFail("expected .vaultMissing, got \(state)")
        }
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 0, "a missing vault must not serve stale tasks")
        let warnings = await store.warnings
        XCTAssertEqual(warnings.count, 0)
        let lastState = await store.lastLoadState
        guard case .vaultMissing? = lastState else {
            return XCTFail("lastLoadState must reflect the last load, got \(String(describing: lastState))")
        }
    }
}
