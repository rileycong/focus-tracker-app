import XCTest
@testable import FocusTracker

/// Tests for the #14 composition root (`AppModel`): fixture-vault loading
/// and exposure, the pinned vault-path change policy (refused while a
/// session is active), reloadVault external-change pickup, the degraded
/// state with the path retained, and the #13 recovery surfacing.
///
/// `AppModel` is `@MainActor`, so the whole suite runs on the main actor;
/// the async bootstrap is the issue-sanctioned explicit startup step and the
/// persistence directory + scheduler + settings suite are injected seams
/// (per #13/#14) so nothing here touches real Application Support or real
/// user preferences.
@MainActor
final class AppModelTests: XCTestCase {

    // MARK: - Test doubles (same seams as #13's coordinator tests)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    /// Manual scheduler: records the last injected interval so tests can
    /// assert re-arming; never fires anything by itself.
    private final class ManualTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        private let lock = NSLock()
        private var interval: TimeInterval?

        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {
            lock.withLock { self.interval = interval }
        }

        func cancel() {
            lock.withLock { interval = nil }
        }

        var pendingInterval: TimeInterval? { lock.withLock { interval } }
    }

    // MARK: - Fixture access (the repo fixture is copied to a temp dir, never touched)

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private var root: URL!
    private var vaultURL: URL!
    private var persistenceDirectory: URL!
    private var suiteName: String!
    private var settings: AppSettings!
    private var scheduler: ManualTickScheduler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "AppModelTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
        scheduler = ManualTickScheduler()
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

    private struct TestFailure: Error {}

    private func makeModel(clock: FakeClock = FakeClock()) -> AppModel {
        AppModel(
            settings: settings,
            persistenceDirectory: persistenceDirectory,
            scheduler: scheduler,
            sessionClock: clock)
    }

    /// A model bootstrapped against the fixture vault (the configured-vault
    /// startup path).
    private func makeConfiguredModel(clock: FakeClock = FakeClock()) async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let model = makeModel(clock: clock)
        await model.bootstrap()
        return model
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

    /// Writes a minimal valid task file into the given vault's `Tasks/`.
    private func writeTaskFile(_ title: String, id: UUID, in vault: URL) throws {
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
            to: vault.appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent("\(title).md"),
            atomically: true,
            encoding: .utf8)
    }

    /// A second, minimal vault with exactly one task (the path-change target).
    private func makeSecondVault(named name: String = "vault-b") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Tasks", isDirectory: true),
            withIntermediateDirectories: true)
        try writeTaskFile("Beta task", id: UUID(), in: url)
        return url
    }

    private func makeSnapshot(
        sessionID: UUID = UUID(), isPaused: Bool = false
    ) -> ActiveSessionSnapshot {
        ActiveSessionSnapshot(
            sessionID: sessionID,
            taskID: UUID(),
            duration: 1500,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 120,
            accumulatedPausedSeconds: isPaused ? 60 : 0,
            pauseCount: isPaused ? 1 : 0,
            isPaused: isPaused,
            segmentStartMonotonic: 42)
    }

    // MARK: - Composition: configured vault loads and exposes tasks

    func testBootstrapWithConfiguredVaultLoadsAndExposesTasks() async throws {
        let model = await makeConfiguredModel()

        _ = try requireLoaded(model.vaultState)
        XCTAssertEqual(
            model.tasks.map(\.title),
            ["Plan Q4 roadmap", "Read Deep Work", "Renew passport"],
            "tasks come back in filename-sorted order")
        XCTAssertEqual(model.vaultURL, vaultURL)

        let store = try XCTUnwrap(model.vaultStore, "the store exists for a configured vault")
        let storeURL = await store.vaultURL
        XCTAssertEqual(storeURL, vaultURL)
        let logs = try XCTUnwrap(model.dailyLogStore)
        let logsURL = await logs.vaultURL
        XCTAssertEqual(logsURL, vaultURL)

        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertTrue(model.isSessionActive == false)
        XCTAssertNil(model.pendingSessionRecovery)
    }

    func testBootstrapWithoutConfiguredPathStaysNotConfigured() async throws {
        let model = makeModel()
        await model.bootstrap()

        guard case .notConfigured = model.vaultState else {
            XCTFail("expected .notConfigured, got \(model.vaultState)")
            return
        }
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNil(model.vaultURL)
        XCTAssertNil(model.vaultStore)
        XCTAssertNil(model.dailyLogStore)
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertNil(model.pendingSessionRecovery)
    }

    // MARK: - Vault path change: accepted path

    func testSetVaultPathFromNotConfiguredChangesStoresAndReloads() async throws {
        let model = makeModel()
        await model.bootstrap()
        let vaultB = try makeSecondVault()

        let outcome = await model.setVaultPath(to: vaultB)

        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(model.vaultURL, vaultB)
        _ = try requireLoaded(model.vaultState)
        XCTAssertEqual(model.tasks.map(\.title), ["Beta task"])
        XCTAssertEqual(
            settings.vaultPath, vaultB.path(percentEncoded: false),
            "the chosen path persists to settings")
        let store = try XCTUnwrap(model.vaultStore)
        let storeURL = await store.vaultURL
        XCTAssertEqual(storeURL, vaultB)
        let logs = try XCTUnwrap(model.dailyLogStore)
        let logsURL = await logs.vaultURL
        XCTAssertEqual(logsURL, vaultB)
    }

    // MARK: - Vault path change: pinned refusal policy

    func testPathChangeWhileSessionActiveIsRefusedAndStoresUnchanged() async throws {
        let model = await makeConfiguredModel()
        let vaultB = try makeSecondVault()
        try model.startSession(taskID: UUID())
        XCTAssertEqual(model.sessionState, .running)

        let outcome = await model.setVaultPath(to: vaultB)

        XCTAssertEqual(outcome, .refusedWhileSessionActive, "the typed refusal outcome")
        // Stores, settings and state are all untouched.
        XCTAssertEqual(model.vaultURL, vaultURL)
        _ = try requireLoaded(model.vaultState)
        XCTAssertEqual(
            model.tasks.map(\.title),
            ["Plan Q4 roadmap", "Read Deep Work", "Renew passport"])
        let store = try XCTUnwrap(model.vaultStore)
        let storeURL = await store.vaultURL
        XCTAssertEqual(storeURL, vaultURL)
        XCTAssertEqual(settings.vaultPath, vaultURL.path(percentEncoded: false))
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertTrue(model.isSessionActive)

        // The refusal is temporary: after the session ends the change goes through.
        _ = try model.endSession()
        let lateOutcome = await model.setVaultPath(to: vaultB)
        XCTAssertEqual(lateOutcome, .changed)
        XCTAssertEqual(model.tasks.map(\.title), ["Beta task"])
    }

    // MARK: - reloadVault picks up external changes

    func testReloadVaultPicksUpExternalChanges() async throws {
        let model = await makeConfiguredModel()
        XCTAssertEqual(model.tasks.count, 3)

        try writeTaskFile("Zebra task", id: UUID(), in: vaultURL)

        await model.reloadVault()

        _ = try requireLoaded(model.vaultState)
        XCTAssertEqual(model.tasks.count, 4)
        XCTAssertTrue(model.tasks.contains { $0.title == "Zebra task" })
    }

    // MARK: - Degraded state with path retained (binding criterion)

    func testVaultDirectoryDeletedAfterConfigYieldsDegradedStateWithPathRetained() async throws {
        let model = await makeConfiguredModel()
        _ = try requireLoaded(model.vaultState)

        try FileManager.default.removeItem(at: vaultURL)
        await model.reloadVault()

        guard case .vaultMissing(let path) = model.vaultState else {
            XCTFail("expected .vaultMissing, got \(model.vaultState)")
            return
        }
        XCTAssertEqual(path, vaultURL)
        XCTAssertEqual(model.vaultURL, vaultURL, "the model retains the path")
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertEqual(
            settings.vaultPath, vaultURL.path(percentEncoded: false),
            "the stored path is never silently cleared")

        // Re-selection is offered and works from the degraded state.
        try FileManager.default.createDirectory(
            at: vaultURL.appendingPathComponent("Tasks", isDirectory: true),
            withIntermediateDirectories: true)
        let reselection = await model.setVaultPath(to: vaultURL)
        XCTAssertEqual(reselection, .changed)
        _ = try requireLoaded(model.vaultState)
        XCTAssertTrue(model.tasks.isEmpty, "empty-but-valid vault after re-selection")
    }

    func testTasksDirectoryDeletedYieldsTasksDirectoryMissingStateWithPathRetained() async throws {
        let model = await makeConfiguredModel()

        try FileManager.default.removeItem(
            at: vaultURL.appendingPathComponent("Tasks", isDirectory: true))
        await model.reloadVault()

        guard case .tasksDirectoryMissing(let path) = model.vaultState else {
            XCTFail("expected .tasksDirectoryMissing, got \(model.vaultState)")
            return
        }
        XCTAssertEqual(path, vaultURL)
        XCTAssertEqual(model.vaultURL, vaultURL)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertEqual(settings.vaultPath, vaultURL.path(percentEncoded: false))
    }

    // MARK: - Recovery surfacing (#13 → #20/#22 hand-off)

    func testSnapshotOnDiskSurfacesPendingResumeOrEndAfterBootstrap() async throws {
        let snapshot = makeSnapshot()
        try FileActiveSessionPersistence(directory: persistenceDirectory).save(snapshot)

        let model = await makeConfiguredModel()

        let pending = try XCTUnwrap(
            model.pendingSessionRecovery, "a stored snapshot surfaces the pending state")
        XCTAssertEqual(pending, snapshot)
        XCTAssertEqual(model.sessionState, .idle, "nothing is restored before the user chooses")
        XCTAssertFalse(model.isSessionActive)
    }

    func testRestoreConsumesPendingSnapshotAndRehydratesSession() async throws {
        let snapshot = makeSnapshot(isPaused: true)
        try FileActiveSessionPersistence(directory: persistenceDirectory).save(snapshot)
        let model = await makeConfiguredModel()
        XCTAssertNotNil(model.pendingSessionRecovery)

        let outcome = try model.restorePendingSession()

        XCTAssertEqual(outcome, .restored)
        XCTAssertNil(model.pendingSessionRecovery, "restore consumes the pending state")
        XCTAssertTrue(model.isSessionActive)
        XCTAssertEqual(model.sessionState, .paused, "the snapshot's phase is carried over")
        XCTAssertEqual(
            scheduler.pendingInterval, AppModel.autosaveIntervalSeconds,
            "the autosave chain re-arms after restore")
        XCTAssertEqual(
            model.focusedSeconds, 120, accuracy: 1e-9,
            "timing continues from the snapshot's accumulators")
    }

    func testDiscardClearsPendingSnapshotInMemoryAndOnDisk() async throws {
        try FileActiveSessionPersistence(directory: persistenceDirectory).save(makeSnapshot())
        let model = await makeConfiguredModel()
        XCTAssertNotNil(model.pendingSessionRecovery)

        XCTAssertEqual(model.discardPendingSession(), .discarded)
        XCTAssertNil(model.pendingSessionRecovery)
        XCTAssertFalse(model.isSessionActive)
        XCTAssertEqual(model.sessionState, .idle)

        // The on-disk snapshot is cleared too: a fresh model over the same
        // persistence directory surfaces nothing.
        let fresh = makeModel()
        await fresh.bootstrap()
        XCTAssertNil(fresh.pendingSessionRecovery)
    }

    func testIdleStartWithNoSnapshotHasNoPendingState() async throws {
        let model = await makeConfiguredModel()

        XCTAssertNil(model.pendingSessionRecovery)
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertFalse(model.isSessionActive)
    }

    func testRestoreAndDiscardWithoutPendingStateAreTypedNoOps() async throws {
        let model = await makeConfiguredModel()

        XCTAssertEqual(try model.restorePendingSession(), .noPendingSession)
        XCTAssertEqual(model.discardPendingSession(), .noPendingSession)
        XCTAssertFalse(model.isSessionActive)
    }

    // MARK: - Session state passthroughs

    func testSessionPassthroughsTrackIdleRunningPausedIdle() async throws {
        let model = await makeConfiguredModel()
        let taskID = try XCTUnwrap(model.tasks.first?.id)

        try model.startSession(taskID: taskID)
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertTrue(model.isSessionActive)

        try model.pauseSession()
        XCTAssertEqual(model.sessionState, .paused)

        try model.resumeSession()
        XCTAssertEqual(model.sessionState, .running)

        let result = try model.endSession()
        XCTAssertEqual(result.taskID, taskID)
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertFalse(model.isSessionActive)
    }
}
