import XCTest
@testable import FocusTracker

/// Tests for the issue #26 first-run vault flows on `AppModel`:
/// `createVault(parentURL:name:)` — the pinned create-path matrix (fresh
/// create / usedExisting with zero writes / scaffold-only-missing cells /
/// collision cells with collision-before-mkdir / the setVaultPath refusal
/// chain including the non-refusing `.postSessionChoice` / empty-name typed
/// error / persistence round-trip) — and the onboarding choose-existing
/// flow `selectExistingVault(at:scaffoldMissingWithConsent:)` (.valid
/// as-is; consent scaffolds only the missing + stores; cancel modifies
/// nothing and stays `.notConfigured`; typed collision error).
///
/// Same seams as the #14 suite: injected settings suite (isolated
/// `UserDefaults`), injected persistence directory, manual scheduler and a
/// fake clock; all disk work happens in a fresh temp directory per test.
@MainActor
final class AppModelVaultCreationTests: XCTestCase {

    // MARK: - Test doubles (same seams as #13/#14's suites)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private final class ManualTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
    }

    // MARK: - Fixtures

    private var root: URL!
    private var parent: URL!
    private var persistenceDirectory: URL!
    private var suiteName: String!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppModelVaultCreationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        parent = root.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "AppModelVaultCreationTests-\(UUID().uuidString)"
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

    private func makeModel() -> AppModel {
        AppModel(
            settings: settings,
            persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(),
            sessionClock: FakeClock())
    }

    private func makeDirectory(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ name: String, content: String, in directory: URL) throws -> Data {
        let data = Data(content.utf8)
        try data.write(
            to: directory.appendingPathComponent(name, isDirectory: false))
        return data
    }

    /// A minimal valid task file (the fixture schema, one file).
    @discardableResult
    private func writeTaskFile(
        _ title: String, status: String = "To Do", in vault: URL
    ) throws -> Data {
        try writeFile(
            "\(title).md",
            content: """
            ---
            id: \(UUID().uuidString)
            title: \(title)
            status: \(status)
            categories:
              - Testing
            ---

            Body of \(title).
            """,
            in: vault.appendingPathComponent("Tasks", isDirectory: true))
    }

    private func makeValidVault(named name: String, taskStatus: String = "To Do") throws -> URL {
        let vault = try makeDirectory(name, in: root)
        try makeDirectory("Tasks", in: vault)
        try makeDirectory("Logs", in: vault)
        try writeTaskFile("Alpha task", status: taskStatus, in: vault)
        return vault
    }

    private func listing(of directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .sorted()
    }

    private struct TestFailure: Error {}

    /// Normalizes a URL to a slash-free path string. URL construction can
    /// pick up a directory-hint trailing slash depending on when the
    /// referenced folder exists on disk (Foundation behavior differs
    /// between construction sites), so outcome assertions compare
    /// normalized paths — the pinned stored-path convention itself
    /// (`setVaultPath`'s `path(percentEncoded: false)` of a plain
    /// pre-existence construction) is asserted separately as a string.
    private func normalizedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func requireLoaded(
        _ state: AppModel.VaultState, file: StaticString = #filePath, line: UInt = #line
    ) throws -> VaultStore.Inventory {
        guard case .loaded(let inventory) = state else {
            XCTFail("expected .loaded(...), got \(state)", file: file, line: line)
            throw TestFailure()
        }
        return inventory
    }

    private func requireNotConfigured(
        _ state: AppModel.VaultState, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .notConfigured = state else {
            XCTFail("expected .notConfigured, got \(state)", file: file, line: line)
            return
        }
    }

    /// A model bootstrapped against a vault containing one In Progress task
    /// with a RUNNING session — the "session active" refusal precondition.
    private func makeRunningSessionModel() async throws -> (AppModel, URL) {
        let vault = try makeValidVault(named: "active-vault", taskStatus: "In Progress")
        settings.vaultPath = vault.path(percentEncoded: false)
        let model = makeModel()
        await model.bootstrap()
        let taskID = try XCTUnwrap(model.tasks.first?.id)
        _ = try await model.startSession(taskID: taskID)
        XCTAssertTrue(model.isSessionActive)
        return (model, vault)
    }

    // MARK: - Create path: fresh create (absent target)

    func testFreshCreateBuildsStructureStoresPathAndLoadsEmpty() async throws {
        let model = makeModel()
        await model.bootstrap()
        let targetPath = root.path(percentEncoded: false) + "/parent/Focus Tracker"

        let outcome = try await model.createVault(parentURL: parent, name: "Focus Tracker")

        guard case .created(let createdURL) = outcome else {
            XCTFail("expected .created, got \(outcome)")
            return
        }
        XCTAssertEqual(normalizedPath(createdURL), targetPath)
        var isDirectory: ObjCBool = false
        for folder in ["Tasks", "Logs"] {
            let path = targetPath + "/" + folder
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                "\(folder)/ was created")
            XCTAssertTrue(isDirectory.boolValue, "\(folder)/ is a directory")
        }
        XCTAssertEqual(settings.vaultPath, targetPath,
                       "the path is stored exactly as setVaultPath stores it")
        XCTAssertEqual(model.vaultURL?.path(percentEncoded: false), targetPath)
        let inventory = try requireLoaded(model.vaultState)
        XCTAssertTrue(inventory.tasks.isEmpty, "a fresh vault's inventory is empty")
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testFreshCreateSanitizesNameButPreservesSpacesAndCase() async throws {
        let model = makeModel()

        let outcome = try await model.createVault(parentURL: parent, name: "My Focus:Vault ")

        let targetPath = root.path(percentEncoded: false) + "/parent/My Focus-Vault"
        guard case .created(let createdURL) = outcome else {
            XCTFail("expected .created, got \(outcome)")
            return
        }
        XCTAssertEqual(normalizedPath(createdURL), targetPath,
                       "':' → '-', trailing space trimmed, spaces/case preserved")
        XCTAssertEqual(settings.vaultPath, targetPath)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: targetPath, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    // MARK: - Create path: valid existing vault (zero writes)

    func testCreateOnValidVaultUsesExistingWithByteIdenticalFiles() async throws {
        let model = makeModel()
        let vault = try makeValidVault(named: "Focus Tracker")
        try makeDirectory(".obsidian", in: vault)
        let strayBytes = try writeFile("keep.txt", content: "stray", in: vault)
        let taskBytes = try Data(
            contentsOf: vault.appendingPathComponent("Tasks/Alpha task.md"))
        let listingBefore = try listing(of: vault)
        let tasksListingBefore = try listing(of: vault.appendingPathComponent("Tasks"))

        let outcome = try await model.createVault(parentURL: root, name: "Focus Tracker")

        XCTAssertEqual(outcome, .usedExisting(vault))
        // Zero writes: the existing files are byte-identical and there are
        // no new entries anywhere.
        XCTAssertEqual(try listing(of: vault), listingBefore, "no new entries")
        XCTAssertEqual(
            try listing(of: vault.appendingPathComponent("Tasks")), tasksListingBefore)
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("Tasks/Alpha task.md")),
            taskBytes, "the task file is byte-identical")
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("keep.txt")), strayBytes)
        // The path is stored and the vault loads (the task is visible).
        XCTAssertEqual(settings.vaultPath, vault.path(percentEncoded: false))
        let inventory = try requireLoaded(model.vaultState)
        XCTAssertEqual(inventory.tasks.map(\.title), ["Alpha task"])
    }

    // MARK: - Create path: scaffold ONLY the missing directories

    func testCreateScaffoldsOnlyMissingTasksAndKeepsExistingContent() async throws {
        let model = makeModel()
        let vault = try makeDirectory("vault", in: root)
        try makeDirectory("Logs", in: vault)
        let logsBytes = try writeFile("keep.txt", content: "logs", in: vault.appendingPathComponent("Logs"))
        try writeFile("root-note.txt", content: "root", in: vault)

        let outcome = try await model.createVault(parentURL: root, name: "vault")

        XCTAssertEqual(outcome, .scaffolded(vault))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Tasks").path(percentEncoded: false),
            isDirectory: &isDirectory) && isDirectory.boolValue, "only Tasks/ was created")
        XCTAssertEqual(
            try listing(of: vault.appendingPathComponent("Logs")), ["keep.txt"],
            "Logs/ content untouched")
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("Logs/keep.txt")), logsBytes)
        XCTAssertEqual(try listing(of: vault), ["Logs", "Tasks", "root-note.txt"])
        XCTAssertEqual(settings.vaultPath, vault.path(percentEncoded: false))
        _ = try requireLoaded(model.vaultState)
    }

    func testCreateScaffoldsOnlyMissingLogsAndKeepsTasksUntouched() async throws {
        let model = makeModel()
        let vault = try makeDirectory("vault", in: root)
        try makeDirectory("Tasks", in: vault)
        let taskBytes = try writeTaskFile("Alpha task", in: vault)

        let outcome = try await model.createVault(parentURL: root, name: "vault")

        XCTAssertEqual(outcome, .scaffolded(vault))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Logs").path(percentEncoded: false),
            isDirectory: &isDirectory) && isDirectory.boolValue, "only Logs/ was created")
        XCTAssertEqual(
            try listing(of: vault.appendingPathComponent("Tasks")), ["Alpha task.md"],
            "Tasks/ content untouched")
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("Tasks/Alpha task.md")),
            taskBytes)
        XCTAssertEqual(settings.vaultPath, vault.path(percentEncoded: false))
        let inventory = try requireLoaded(model.vaultState)
        XCTAssertEqual(inventory.tasks.map(\.title), ["Alpha task"])
    }
    func testCreateScaffoldsBothMissingInExistingEmptyDirectory() async throws {
        let model = makeModel()
        let vault = try makeDirectory("vault", in: root)

        let outcome = try await model.createVault(parentURL: root, name: "vault")

        XCTAssertEqual(outcome, .scaffolded(vault))
        XCTAssertEqual(try listing(of: vault), ["Logs", "Tasks"])
        XCTAssertEqual(settings.vaultPath, vault.path(percentEncoded: false))
        _ = try requireLoaded(model.vaultState)
    }

    // MARK: - Create path: collisions (collision detection BEFORE any mkdir)

    func testCreateWithFileAtTargetIsCollisionAndModifiesNothing() async throws {
        let model = makeModel()
        await model.bootstrap()
        let fileBytes = try writeFile("Vault", content: "occupant", in: parent)
        let targetPath = root.path(percentEncoded: false) + "/parent/Vault"

        let outcome = try await model.createVault(parentURL: parent, name: "Vault")

        guard case .nameCollision(let collidedURL) = outcome else {
            XCTFail("expected .nameCollision, got \(outcome)")
            return
        }
        XCTAssertEqual(normalizedPath(collidedURL), targetPath)
        XCTAssertEqual(try listing(of: parent), ["Vault"], "nothing modified")
        XCTAssertEqual(
            try Data(contentsOf: parent.appendingPathComponent("Vault")), fileBytes)
        XCTAssertNil(settings.vaultPath, "the path is NOT stored")
        requireNotConfigured(model.vaultState)
        XCTAssertNil(model.vaultURL)
    }

    func testCreateWithTasksOccupiedAndLogsMissingCreatesNoLogs() async throws {
        let model = makeModel()
        await model.bootstrap()
        let vault = try makeDirectory("vault", in: root)
        let tasksBytes = try writeFile("Tasks", content: "occupant", in: vault)

        let outcome = try await model.createVault(parentURL: root, name: "vault")

        // The pinned example: collision detection precedes any mkdir —
        // `Logs/` must NOT be created around the occupied `Tasks`.
        XCTAssertEqual(outcome, .nameCollision(vault))
        XCTAssertEqual(try listing(of: vault), ["Tasks"], "no Logs/ was created")
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("Tasks")), tasksBytes)
        XCTAssertNil(settings.vaultPath)
        requireNotConfigured(model.vaultState)
    }

    // MARK: - Create path: the pinned refusal chain

    func testCreateRefusedWhileSessionActiveTouchesNothing() async throws {
        let (model, configuredVault) = try await makeRunningSessionModel()
        let target = parent.appendingPathComponent("Focus Tracker")

        let outcome = try await model.createVault(parentURL: parent, name: "Focus Tracker")

        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path(percentEncoded: false)),
            "nothing was created on disk")
        XCTAssertEqual(
            settings.vaultPath, configuredVault.path(percentEncoded: false),
            "settings untouched")
        XCTAssertEqual(model.vaultURL, configuredVault)
        _ = try requireLoaded(model.vaultState)
        XCTAssertTrue(model.isSessionActive)
    }

    func testCreateRefusedWhileEndingSessionTouchesNothing() async throws {
        let (model, configuredVault) = try await makeRunningSessionModel()
        _ = try model.endSession()
        let target = parent.appendingPathComponent("Focus Tracker")

        let outcome = try await model.createVault(parentURL: parent, name: "Focus Tracker")

        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        XCTAssertEqual(
            settings.vaultPath, configuredVault.path(percentEncoded: false))
        XCTAssertTrue(model.isSessionActive == false, "the engine already ended")
    }

    func testCreateRefusedWhileBreakActiveTouchesNothing() async throws {
        let (model, configuredVault) = try await makeRunningSessionModel()
        _ = try model.endSession()
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 3
        form.energyRating = 3
        _ = try await model.submitEndOfSession(form)
        try model.takeBreak()
        let target = parent.appendingPathComponent("Focus Tracker")

        let outcome = try await model.createVault(parentURL: parent, name: "Focus Tracker")

        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        XCTAssertEqual(
            settings.vaultPath, configuredVault.path(percentEncoded: false))
    }

    func testCreateDuringPostSessionChoiceIsNotRefused() async throws {
        // The pinned policy (the #14/#23 one): the choice phase does NOT
        // refuse — nothing is pending a write during the choice.
        let (model, _) = try await makeRunningSessionModel()
        _ = try model.endSession()
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 3
        form.energyRating = 3
        _ = try await model.submitEndOfSession(form)
        guard case .postSessionChoice = model.appPhase else {
            XCTFail("expected .postSessionChoice, got \(model.appPhase)")
            return
        }

        let outcome = try await model.createVault(parentURL: parent, name: "Focus Tracker")

        let targetPath = root.path(percentEncoded: false) + "/parent/Focus Tracker"
        guard case .created(let createdURL) = outcome else {
            XCTFail("expected .created, got \(outcome)")
            return
        }
        XCTAssertEqual(normalizedPath(createdURL), targetPath)
        XCTAssertEqual(settings.vaultPath, targetPath)
        _ = try requireLoaded(model.vaultState)
    }

    // MARK: - Create path: the typed empty-name error

    func testCreateWithEmptyAfterSanitizeNameThrowsAndModifiesNothing() async throws {
        let model = makeModel()
        await model.bootstrap()

        do {
            _ = try await model.createVault(parentURL: parent, name: " . ")
            XCTFail("expected the typed emptyAfterSanitize error")
        } catch let error as VaultFolderNameSanitizer.SanitizationError {
            XCTAssertEqual(error, .emptyAfterSanitize)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(try listing(of: parent), [], "nothing was created")
        XCTAssertNil(settings.vaultPath)
        requireNotConfigured(model.vaultState)
    }

    // MARK: - Create path: persistence round-trip

    func testFreshCreatePersistsAcrossAFreshModelOverTheSameSuite() async throws {
        let model = makeModel()
        await model.bootstrap()
        let targetPath = root.path(percentEncoded: false) + "/parent/Focus Tracker"
        _ = try await model.createVault(parentURL: parent, name: "Focus Tracker")

        // A fresh AppModel over the SAME settings suite bootstraps .loaded.
        let freshPersistence = root.appendingPathComponent("persistence-2")
        let fresh = AppModel(
            settings: settings,
            persistenceDirectory: freshPersistence,
            scheduler: ManualTickScheduler(),
            sessionClock: FakeClock())
        await fresh.bootstrap()

        XCTAssertEqual(
            fresh.vaultURL.map(normalizedPath), targetPath,
            "the stored path round-trips to the created vault")
        let inventory = try requireLoaded(fresh.vaultState)
        XCTAssertTrue(inventory.tasks.isEmpty)
    }

    // MARK: - Choose-existing: .valid used as-is

    func testSelectValidVaultAppliesAsTodayWithoutConsent() async throws {
        let model = makeModel()
        await model.bootstrap()
        let vault = try makeValidVault(named: "Focus Tracker")
        let listingBefore = try listing(of: vault)

        let outcome = try await model.selectExistingVault(
            at: vault, scaffoldMissingWithConsent: false)

        XCTAssertEqual(outcome, .selected(vault), ".valid needs no consent")
        XCTAssertEqual(try listing(of: vault), listingBefore, "zero writes")
        XCTAssertEqual(settings.vaultPath, vault.path(percentEncoded: false))
        let inventory = try requireLoaded(model.vaultState)
        XCTAssertEqual(inventory.tasks.map(\.title), ["Alpha task"])
    }

    // MARK: - Choose-existing: consent scaffolds only the missing

    func testSelectMismatchWithConsentScaffoldsOnlyMissingAndStores() async throws {
        let model = makeModel()
        await model.bootstrap()
        let vault = try makeDirectory("vault", in: root)
        try makeDirectory("Logs", in: vault)
        let logsBytes = try writeFile("keep.txt", content: "logs", in: vault.appendingPathComponent("Logs"))

        let outcome = try await model.selectExistingVault(
            at: vault, scaffoldMissingWithConsent: true)

        XCTAssertEqual(outcome, .scaffolded(vault))
        XCTAssertEqual(
            try listing(of: vault), ["Logs", "Tasks"], "only Tasks/ was scaffolded")
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("Logs/keep.txt")), logsBytes)
        XCTAssertEqual(settings.vaultPath, vault.path(percentEncoded: false))
        _ = try requireLoaded(model.vaultState)
    }

    // MARK: - Choose-existing: cancel modifies nothing

    func testSelectMismatchCancelModifiesNothingAndStaysNotConfigured() async throws {
        let model = makeModel()
        await model.bootstrap()
        let vault = try makeDirectory("vault", in: root)
        try makeDirectory("Logs", in: vault)
        try writeFile("keep.txt", content: "logs", in: vault.appendingPathComponent("Logs"))
        let listingBefore = try listing(of: vault)

        let outcome = try await model.selectExistingVault(
            at: vault, scaffoldMissingWithConsent: false)

        XCTAssertEqual(outcome, .cancelled(vault))
        XCTAssertEqual(try listing(of: vault), listingBefore, "nothing on disk modified")
        XCTAssertNil(settings.vaultPath, "the path is NOT stored")
        requireNotConfigured(model.vaultState)
        XCTAssertNil(model.vaultURL)
        XCTAssertNil(model.vaultStore)
        XCTAssertNil(model.dailyLogStore)
    }

    // MARK: - Choose-existing: typed collision error

    func testSelectCollisionIsTypedErrorModifyingNothing() async throws {
        let model = makeModel()
        await model.bootstrap()
        let vault = try makeDirectory("vault", in: root)
        let tasksBytes = try writeFile("Tasks", content: "occupant", in: vault)
        try makeDirectory("Logs", in: vault)
        let listingBefore = try listing(of: vault)

        let outcome = try await model.selectExistingVault(
            at: vault, scaffoldMissingWithConsent: true)

        XCTAssertEqual(outcome, .nameCollision(vault))
        XCTAssertEqual(try listing(of: vault), listingBefore, "nothing modified")
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("Tasks")), tasksBytes)
        XCTAssertNil(settings.vaultPath)
        requireNotConfigured(model.vaultState)
    }

    // MARK: - Choose-existing: defensive refusal parity

    func testSelectRefusedWhileSessionActiveTouchesNothing() async throws {
        let (model, configuredVault) = try await makeRunningSessionModel()
        let vault = try makeValidVault(named: "other-vault")

        let outcome = try await model.selectExistingVault(
            at: vault, scaffoldMissingWithConsent: false)

        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        XCTAssertEqual(
            settings.vaultPath, configuredVault.path(percentEncoded: false))
        XCTAssertEqual(model.vaultURL, configuredVault)
        XCTAssertTrue(model.isSessionActive)
    }
}
