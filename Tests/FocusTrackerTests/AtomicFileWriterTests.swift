import XCTest
@testable import FocusTracker

final class AtomicFileWriterTests: XCTestCase {

    // MARK: - Fixtures and helpers

    private var root: URL!
    private var writer: AtomicFileWriter!

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault/Tasks", isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AtomicFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        writer = AtomicFileWriter()
    }

    override func tearDownWithError() throws {
        if let root {
            restoreWritePermissionRecursively(in: root)
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    /// The read-only-directory test deliberately leaves a directory without
    /// write permission; undo that so teardown can delete the tree.
    private func restoreWritePermissionRecursively(in directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        if let children = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) {
            for child in children {
                let childURL = directory.appendingPathComponent(child)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: childURL.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    restoreWritePermissionRecursively(in: childURL)
                }
            }
        }
    }

    private func tempFileNames(in directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".tmp") }
    }

    private func assertNoTempFiles(
        in directory: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try tempFileNames(in: directory), [],
            "temp files must be cleaned up", file: file, line: line)
    }

    private func assertThrows(
        _ expression: @autoclosure () throws -> some Any,
        _ expected: AtomicFileWriterError,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? AtomicFileWriterError, expected,
                "expected \(expected), got \(error) \(message())",
                file: file, line: line)
        }
    }

    /// Test-only seam recorder: records hook events and can inject one failure.
    private final class HookRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AtomicFileWriter.HookEvent] = []
        private var failurePoint: AtomicFileWriter.HookEvent?
        private var failureError: AtomicFileWriterError?

        func fail(at point: AtomicFileWriter.HookEvent, with error: AtomicFileWriterError) {
            lock.lock()
            defer { lock.unlock() }
            failurePoint = point
            failureError = error
        }

        var hook: AtomicFileWriter.Hook {
            { [self] event in
                lock.lock()
                defer { lock.unlock() }
                events.append(event)
                if let point = failurePoint, Self.matchesShape(point, event),
                   let failure = failureError {
                    throw failure
                }
            }
        }

        var recordedEvents: [AtomicFileWriter.HookEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        var tempURLs: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return events.compactMap { event in
                if case .tempCreated(let url) = event { return url }
                return nil
            }
        }

        /// Shape match ignoring associated values (tests cannot predict UUIDs).
        private static func matchesShape(
            _ pattern: AtomicFileWriter.HookEvent, _ event: AtomicFileWriter.HookEvent
        ) -> Bool {
            switch (pattern, event) {
            case (.tempCreated, .tempCreated),
                 (.beforeRename, .beforeRename),
                 (.beforeDirectorySync, .beforeDirectorySync):
                return true
            default:
                return false
            }
        }
    }

    // MARK: - (a) Temp-file-then-rename behavior

    func testWriteCreatesTargetWithExactBytesAndLeavesNoTempFiles() throws {
        let target = root.appendingPathComponent("Task.md")
        let payload = Data("frontmatter and body bytes".utf8)
        try writer.write(payload, to: target)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        try assertNoTempFiles(in: root)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)),
            ["Task.md"])
    }

    func testTempFileIsCreatedInTheSameDirectoryAsTarget() throws {
        let target = root.appendingPathComponent("Task.md")
        let recorder = HookRecorder()
        let hooked = AtomicFileWriter(hook: recorder.hook)

        try hooked.write(Data("payload".utf8), to: target)

        let tempURLs = recorder.tempURLs
        XCTAssertEqual(tempURLs.count, 1, "exactly one temp file per write")
        let tempURL = tempURLs[0]
        XCTAssertEqual(tempURL.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertNotEqual(tempURL, target)
        XCTAssertTrue(tempURL.lastPathComponent.hasSuffix(".tmp"))
        // The default durability never touches the parent directory.
        XCTAssertEqual(recorder.recordedEvents.map(Self.eventKind), ["tempCreated", "beforeRename"])
        // The temp file was consumed by the rename: nothing is left over.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testOverwriteReplacesOldContentCompletely() throws {
        let target = root.appendingPathComponent("Task.md")
        try writer.write(Data(String(repeating: "A", count: 10_000).utf8), to: target)
        let replacement = Data("short replacement".utf8)
        try writer.write(replacement, to: target)
        XCTAssertEqual(try Data(contentsOf: target), replacement)
        try assertNoTempFiles(in: root)
    }

    func testWriteEmptyDataCreatesAnEmptyFile() throws {
        let target = root.appendingPathComponent("Empty.md")
        try writer.write(Data(), to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data())
        try assertNoTempFiles(in: root)
    }

    // MARK: - (b) Failure injection: old content survives, typed error, cleanup

    func testInjectedFailureAfterTempFileCreatedCleansUpTempFileAndKeepsOldContent() throws {
        let target = root.appendingPathComponent("Task.md")
        let old = Data("OLD CONTENT".utf8)
        try writer.write(old, to: target)

        let recorder = HookRecorder()
        recorder.fail(
            at: .tempCreated(URL(fileURLWithPath: "/irrelevant")),
            with: .posixError(code: .EIO, operation: "test-injection", path: "hook"))
        let hooked = AtomicFileWriter(hook: recorder.hook)

        assertThrows(
            try hooked.write(Data("NEW CONTENT".utf8), to: target),
            .posixError(code: .EIO, operation: "test-injection", path: "hook"))
        XCTAssertEqual(try Data(contentsOf: target), old, "old content must survive a failed write")
        try assertNoTempFiles(in: root)
    }

    func testInjectedFailureBeforeRenameCleansUpTempFileAndKeepsOldContent() throws {
        let target = root.appendingPathComponent("Task.md")
        let old = Data("OLD CONTENT".utf8)
        try writer.write(old, to: target)

        let recorder = HookRecorder()
        recorder.fail(
            at: .beforeRename,
            with: .posixError(code: .EIO, operation: "test-injection", path: "hook"))
        let hooked = AtomicFileWriter(hook: recorder.hook)

        assertThrows(
            try hooked.write(Data("NEW CONTENT".utf8), to: target),
            .posixError(code: .EIO, operation: "test-injection", path: "hook"))
        XCTAssertEqual(try Data(contentsOf: target), old, "old content must survive a failed write")
        try assertNoTempFiles(in: root)
    }

    func testWriteIntoMissingDirectoryThrowsDirectoryMissing() throws {
        let missing = root.appendingPathComponent("Nope", isDirectory: true)
        let target = missing.appendingPathComponent("Task.md")
        assertThrows(
            try writer.write(Data("x".utf8), to: target),
            .directoryMissing(path: missing.path(percentEncoded: false)))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)),
            [], "no partial state may be created")
    }

    func testWriteIntoReadOnlyDirectoryThrowsPermissionErrorAndKeepsOldContent() throws {
        guard getuid() != 0 else {
            throw XCTSkip("file permissions are not enforced when running as root")
        }
        let directory = root.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("Task.md")
        let old = Data("OLD CONTENT".utf8)
        try old.write(to: target)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        }

        XCTAssertThrowsError(try writer.write(Data("NEW CONTENT".utf8), to: target)) { error in
            guard case .posixError(let code, let operation, _) = error as? AtomicFileWriterError else {
                return XCTFail("expected posixError, got \(error)")
            }
            XCTAssertEqual(code, .EACCES, "permission denied must surface as EACCES")
            XCTAssertEqual(operation, "open-temp-file")
        }
        XCTAssertEqual(try Data(contentsOf: target), old, "old content must survive")
        try assertNoTempFiles(in: directory)
    }

    func testWriteOverAnExistingDirectoryFailsWithoutTouchingIt() throws {
        let target = root.appendingPathComponent("Subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

        XCTAssertThrowsError(try writer.write(Data("NEW CONTENT".utf8), to: target)) { error in
            guard case .renameFailed(let code, let path) = error as? AtomicFileWriterError else {
                return XCTFail("expected renameFailed, got \(error)")
            }
            XCTAssertEqual(code, .EISDIR)
            XCTAssertEqual(path, target.path(percentEncoded: false))
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "the pre-existing directory must be untouched")
        try assertNoTempFiles(in: root)
    }

    // MARK: - Durability variant

    func testStrictDurabilitySyncsParentDirectoryAndWritesContent() throws {
        let target = root.appendingPathComponent("Task.md")
        let recorder = HookRecorder()
        let hooked = AtomicFileWriter(hook: recorder.hook)
        let payload = Data("durable payload".utf8)

        try hooked.write(payload, to: target, durability: .strict)

        XCTAssertEqual(
            recorder.recordedEvents.map(Self.eventKind),
            ["tempCreated", "beforeRename", "beforeDirectorySync"],
            ".strict must fsync the parent directory after the rename")
        XCTAssertEqual(try Data(contentsOf: target), payload)
    }

    func testInjectedDirectorySyncFailureSurfacesTypedErrorAndKeepsNewContent() throws {
        let target = root.appendingPathComponent("Task.md")
        let old = Data("OLD CONTENT".utf8)
        try writer.write(old, to: target)

        let recorder = HookRecorder()
        recorder.fail(
            at: .beforeDirectorySync,
            with: .posixError(code: .EIO, operation: "test-injection", path: "hook"))
        let hooked = AtomicFileWriter(hook: recorder.hook)

        assertThrows(
            try hooked.write(Data("NEW CONTENT".utf8), to: target, durability: .strict),
            .posixError(code: .EIO, operation: "test-injection", path: "hook"))
        // The rename has already happened when the directory fsync runs, so the
        // target holds the NEW content — documented .strict failure semantics.
        XCTAssertEqual(try Data(contentsOf: target), Data("NEW CONTENT".utf8))
        try assertNoTempFiles(in: root)
    }

    // MARK: - Move

    func testMoveSuccessRemovesSourceAndWritesDestination() throws {
        let source = root.appendingPathComponent("Old Title.md")
        let destination = root.appendingPathComponent("New Title.md")
        let content = Data("task bytes".utf8)
        try content.write(to: source)

        try writer.move(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), content)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "on success the source no longer exists")
        try assertNoTempFiles(in: root)
    }

    func testMoveToExistingDestinationThrowsDestinationExistsAndTouchesNeitherFile() throws {
        let source = root.appendingPathComponent("A.md")
        let destination = root.appendingPathComponent("B.md")
        try Data("A".utf8).write(to: source)
        try Data("B".utf8).write(to: destination)

        assertThrows(
            try writer.move(from: source, to: destination),
            .destinationExists(path: destination.path(percentEncoded: false)))

        XCTAssertEqual(try Data(contentsOf: destination), Data("B".utf8), "destination untouched")
        XCTAssertEqual(try Data(contentsOf: source), Data("A".utf8), "source untouched")
    }

    func testMoveOntoSamePathIsANoOpSuccess() throws {
        let source = root.appendingPathComponent("A.md")
        let content = Data("A".utf8)
        try content.write(to: source)
        let recorder = HookRecorder()
        let hooked = AtomicFileWriter(hook: recorder.hook)

        try hooked.move(from: source, to: source)

        XCTAssertTrue(
            recorder.recordedEvents.isEmpty, "same-path move must not perform any filesystem call")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: source), content)
    }

    func testMoveWithMissingSourceThrowsFileMissing() throws {
        let missing = root.appendingPathComponent("Missing.md")
        assertThrows(
            try writer.move(from: missing, to: root.appendingPathComponent("B.md")),
            .fileMissing(path: missing.path(percentEncoded: false)))
    }

    func testMoveIntoMissingDirectoryThrowsDirectoryMissing() throws {
        let source = root.appendingPathComponent("A.md")
        try Data("A".utf8).write(to: source)
        let missingParent = root.appendingPathComponent("Nope", isDirectory: true)
        let destination = missingParent.appendingPathComponent("B.md")

        assertThrows(
            try writer.move(from: source, to: destination),
            .directoryMissing(path: missingParent.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "source untouched")
    }

    // MARK: - Delete

    func testDeleteRemovesExistingFile() throws {
        let target = root.appendingPathComponent("Task.md")
        try Data("bytes".utf8).write(to: target)

        try writer.delete(target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testDeleteMissingFileThrowsFileMissing() throws {
        let missing = root.appendingPathComponent("Missing.md")
        assertThrows(
            try writer.delete(missing),
            .fileMissing(path: missing.path(percentEncoded: false)))
    }

    // MARK: - Concurrency (chosen strategy: last-wins via unique temp names)

    func testConcurrentWritesToSamePathEndWithExactlyOneCompletePayload() async throws {
        let recorder = HookRecorder()
        let hookedWriter = AtomicFileWriter(hook: recorder.hook)
        let target = root.appendingPathComponent("Task.md")
        let payloads: [Data] = (0..<24).map { index in
            Data(("START-\(index)-" + String(repeating: "x", count: 8192) + "-END").utf8)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    try hookedWriter.write(payload, to: target)
                }
            }
            try await group.waitForAll()
        }

        let tempURLs = recorder.tempURLs
        XCTAssertEqual(tempURLs.count, payloads.count, "one unique temp file per write")
        XCTAssertEqual(Set(tempURLs).count, tempURLs.count, "temp names must never collide")
        let final = try Data(contentsOf: target)
        XCTAssertTrue(
            payloads.contains(final),
            "the final file must be exactly one complete payload — never interleaved or partial")
        try assertNoTempFiles(in: root)
    }

    // MARK: - (c) Integration with the #4 codec (writer stays content-agnostic)

    func testSerializeAtomicWriteParseRoundTripPreservesTaskAndBody() throws {
        let originalText = try String(
            contentsOf: Self.fixturesDirectory.appendingPathComponent("Plan Q4 roadmap.md"),
            encoding: .utf8)
        let (frontmatter, originalBody) = try FrontmatterCodec.split(originalText)
        let task = try FrontmatterCodec.decodeTask(frontmatter: frontmatter)

        let serialized = Data(FrontmatterCodec.encode(task: task, body: originalBody).utf8)
        let target = root.appendingPathComponent("Plan Q4 roadmap.md")
        try writer.write(serialized, to: target)

        let written = try String(contentsOf: target, encoding: .utf8)
        let (writtenFrontmatter, writtenBody) = try FrontmatterCodec.split(written)
        XCTAssertEqual(try FrontmatterCodec.decodeTask(frontmatter: writtenFrontmatter), task)
        XCTAssertEqual(writtenBody, originalBody, "the body must survive byte-for-byte")
    }

    private static func eventKind(_ event: AtomicFileWriter.HookEvent) -> String {
        switch event {
        case .tempCreated: return "tempCreated"
        case .beforeRename: return "beforeRename"
        case .beforeDirectorySync: return "beforeDirectorySync"
        }
    }
}
