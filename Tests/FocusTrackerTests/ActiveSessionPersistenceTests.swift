import XCTest
@testable import FocusTracker

/// Tests for the #13 `FileActiveSessionPersistence`: round-trip equality,
/// missing/corrupt handling with typed error + quarantine (never
/// overwriting), atomic save via the #5 `AtomicFileWriter` (failure hook at
/// the rename point), clear no-op semantics and directory auto-creation.
final class ActiveSessionPersistenceTests: XCTestCase {

    // MARK: - Fixtures and helpers

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ActiveSessionPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makeSnapshot(sessionID: UUID = UUID()) -> ActiveSessionSnapshot {
        ActiveSessionSnapshot(
            sessionID: sessionID,
            taskID: UUID(),
            duration: 1500,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 600,
            accumulatedPausedSeconds: 90,
            pauseCount: 1,
            isPaused: true,
            segmentStartMonotonic: 690)
    }

    private func makePersistence(
        directory: URL? = nil, writer: AtomicFileWriter = AtomicFileWriter()
    ) -> FileActiveSessionPersistence {
        FileActiveSessionPersistence(
            directory: directory ?? root.appendingPathComponent("storage", isDirectory: true),
            writer: writer)
    }

    private var storageDirectory: URL {
        root.appendingPathComponent("storage", isDirectory: true)
    }

    private var snapshotFile: URL {
        storageDirectory.appendingPathComponent("active-session.json")
    }

    private func directoryContents(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .sorted()
    }

    /// Test-only seam recorder for the #5 writer hook (same pattern as
    /// AtomicFileWriterTests): records a failure point; any matching hook
    /// event aborts the write with a typed error.
    private final class HookRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var failurePoint: AtomicFileWriter.HookEvent?

        func fail(at point: AtomicFileWriter.HookEvent) {
            lock.withLock { failurePoint = point }
        }

        var hook: AtomicFileWriter.Hook {
            { [self] event in
                let point = lock.withLock { failurePoint }
                if let point, Self.matchesShape(point, event) {
                    throw AtomicFileWriterError.posixError(
                        code: .EIO, operation: "test-injection", path: "hook")
                }
            }
        }

        private static func matchesShape(
            _ pattern: AtomicFileWriter.HookEvent, _ event: AtomicFileWriter.HookEvent
        ) -> Bool {
            switch (pattern, event) {
            case (.tempCreated, .tempCreated), (.beforeRename, .beforeRename):
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Round trip (criterion 7)

    func testSaveLoadRoundTripEquality() throws {
        let persistence = makePersistence()
        let snapshot = makeSnapshot()

        try persistence.save(snapshot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotFile.path))
        XCTAssertEqual(try persistence.load(), snapshot, "round-trip equality")
    }

    // MARK: - Missing / absent (criterion 2, 7)

    func testLoadWithMissingFileReturnsNil() throws {
        let persistence = makePersistence()
        XCTAssertNil(try persistence.load(), "missing file → nil, never an error")
    }

    func testLoadWithMissingDirectoryReturnsNil() throws {
        // Not even the directory exists yet (no save happened): still nil.
        let persistence = makePersistence(
            directory: root.appendingPathComponent("never-created", isDirectory: true))
        XCTAssertNil(try persistence.load())
    }

    // MARK: - Clear (criterion 2, 7)

    func testClearRemovesSnapshotFile() throws {
        let persistence = makePersistence()
        try persistence.save(makeSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotFile.path))

        try persistence.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotFile.path))
        XCTAssertNil(try persistence.load())
    }

    func testClearWhenAbsentIsANoOpSuccess() throws {
        // No file in an existing directory...
        let persistence = makePersistence()
        XCTAssertNoThrow(try persistence.clear())

        // ...and not even a directory: the end/clear path never fails
        // because nothing was saved (PRD §18).
        let fresh = makePersistence(
            directory: root.appendingPathComponent("never-created", isDirectory: true))
        XCTAssertNoThrow(try fresh.clear())
    }

    // MARK: - Corrupt snapshot: typed error + quarantine (criterion 2, 7)

    func testCorruptSnapshotThrowsTypedErrorQuarantinesAndTreatsAsAbsent() throws {
        let persistence = makePersistence()
        let corruptBytes = Data("{ this is not a snapshot".utf8)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try corruptBytes.write(to: snapshotFile)

        // The typed error surfaces — never a silent nil masquerade.
        XCTAssertThrowsError(try persistence.load()) { error in
            guard case ActiveSessionPersistenceError.corruptSnapshot(let path) = error else {
                return XCTFail("expected corruptSnapshot, got \(error)")
            }
            XCTAssertEqual(
                path,
                storageDirectory.appendingPathComponent("active-session.json.corrupt")
                    .path(percentEncoded: false))
        }

        // Quarantined: renamed out of the way, bytes preserved for inspection.
        let quarantine = storageDirectory.appendingPathComponent("active-session.json.corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotFile.path))
        XCTAssertEqual(try Data(contentsOf: quarantine), corruptBytes)

        // Subsequent load: treated as absent.
        XCTAssertNil(try persistence.load())
    }

    func testSecondCorruptSnapshotGetsUniqueQuarantineNameWithoutOverwriting() throws {
        let persistence = makePersistence()
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        let firstBytes = Data("first corrupt payload".utf8)
        try firstBytes.write(to: snapshotFile)
        _ = try? persistence.load()  // quarantines as .corrupt

        let secondBytes = Data("second corrupt payload".utf8)
        try secondBytes.write(to: snapshotFile)
        _ = try? persistence.load()  // must NOT overwrite; quarantines as .corrupt-2

        // Both quarantines exist with their original bytes; snapshot gone.
        XCTAssertEqual(
            try Data(contentsOf: storageDirectory.appendingPathComponent("active-session.json.corrupt")),
            firstBytes)
        XCTAssertEqual(
            try Data(contentsOf: storageDirectory.appendingPathComponent("active-session.json.corrupt-2")),
            secondBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotFile.path))
        XCTAssertEqual(
            try directoryContents(storageDirectory),
            ["active-session.json.corrupt", "active-session.json.corrupt-2"])
    }

    func testDecodableJSONWithWrongSchemaIsCorruptNotAbsent() throws {
        let persistence = makePersistence()
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try Data("{\"unrelated\": true}".utf8).write(to: snapshotFile)

        XCTAssertThrowsError(try persistence.load()) { error in
            XCTAssertTrue(
                error is ActiveSessionPersistenceError,
                "schema-mismatched JSON must surface as corrupt, got \(error)")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storageDirectory.appendingPathComponent("active-session.json.corrupt").path))
    }

    // MARK: - Atomic save via #5 writer (criterion 2, 7)

    func testSaveFailureAtRenamePointKeepsPreviousSnapshotAndLeavesNoTempLitter() throws {
        let persistence = makePersistence()
        let oldSnapshot = makeSnapshot()
        try persistence.save(oldSnapshot)

        let recorder = HookRecorder()
        recorder.fail(at: .beforeRename)
        let hooked = makePersistence(writer: AtomicFileWriter(hook: recorder.hook))

        XCTAssertThrowsError(try hooked.save(makeSnapshot(sessionID: UUID())))

        // The target still holds the OLD complete snapshot; no temp files.
        XCTAssertEqual(try persistence.load(), oldSnapshot)
        XCTAssertEqual(try directoryContents(storageDirectory), ["active-session.json"])
    }

    func testSaveFailureAfterTempCreationKeepsPreviousSnapshotAndLeavesNoTempLitter() throws {
        let persistence = makePersistence()
        let oldSnapshot = makeSnapshot()
        try persistence.save(oldSnapshot)

        let recorder = HookRecorder()
        recorder.fail(at: .tempCreated(URL(fileURLWithPath: "/irrelevant")))
        let hooked = makePersistence(writer: AtomicFileWriter(hook: recorder.hook))

        XCTAssertThrowsError(try hooked.save(makeSnapshot(sessionID: UUID())))

        XCTAssertEqual(try persistence.load(), oldSnapshot)
        XCTAssertEqual(try directoryContents(storageDirectory), ["active-session.json"])
    }

    // MARK: - Directory auto-creation (criterion 2, 7)

    func testSaveAutoCreatesInjectedNonExistentNestedDirectory() throws {
        let nested = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("FocusTracker", isDirectory: true)
        let persistence = makePersistence(directory: nested)
        let snapshot = makeSnapshot()

        try persistence.save(snapshot)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: nested.appendingPathComponent("active-session.json").path),
            "the nested directory was auto-created on first save")
        XCTAssertEqual(try persistence.load(), snapshot)
    }
}
