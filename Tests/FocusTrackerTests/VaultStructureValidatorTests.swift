import XCTest
@testable import FocusTracker

/// Tests for the issue #26 pure helpers: the pinned
/// `VaultStructureValidator` classification (structure outcomes + the
/// pinned collision-over-missing precedence) and the
/// `VaultFolderNameSanitizer` character policy (the house slug policy of
/// `VaultStore.slug(from:)` WITHOUT `.md`/`untitled`).
///
/// All filesystem classification tests run in a fresh temp directory per
/// test; the sanitizer tests are pure.
final class VaultStructureValidatorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VaultStructureValidatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeDirectory(_ name: String, in parent: URL? = nil) throws {
        try FileManager.default.createDirectory(
            at: (parent ?? root).appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true)
    }

    private func makeFile(_ name: String, in parent: URL? = nil) throws {
        try Data("irrelevant".utf8).write(
            to: (parent ?? root).appendingPathComponent(name, isDirectory: false))
    }

    // MARK: - Structure outcomes

    func testValidVaultWithExtraObsidianAndStrayFilesTolerated() throws {
        try makeDirectory("Tasks")
        try makeDirectory("Logs")
        // Extra content — Obsidian-owned and stray — is irrelevant.
        try makeDirectory(".obsidian")
        try makeFile("notes.txt")
        try makeDirectory("Projects")
        try makeFile("stray.md", in: root.appendingPathComponent("Tasks"))
        try makeFile(".DS_Store", in: root.appendingPathComponent("Logs"))

        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .valid)
    }

    func testMissingTasks() throws {
        try makeDirectory("Logs")

        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .missingTasks)
    }

    func testMissingLogs() throws {
        try makeDirectory("Tasks")

        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .missingLogs)
    }

    func testBothMissing() throws {
        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .bothMissing)
    }

    func testNonExistentRootClassifiesAsBothMissing() throws {
        // Documented behavior: a path that does not exist at all has
        // neither Tasks/ nor Logs/, so it classifies `.bothMissing` — the
        // fresh-create path never consults it (it checks the target
        // itself first), and the choose-existing pre-check cannot reach it
        // (the panel only returns directories).
        let absent = root.appendingPathComponent("does-not-exist")
        XCTAssertEqual(
            VaultStructureValidator.validate(at: absent), .bothMissing)
    }

    // MARK: - Name collisions (a non-directory occupies a folder path)

    func testTasksOccupiedByFileIsNameCollision() throws {
        try makeFile("Tasks")
        try makeDirectory("Logs")

        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .nameCollision)
    }

    func testLogsOccupiedByFileIsNameCollision() throws {
        try makeDirectory("Tasks")
        try makeFile("Logs")

        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .nameCollision)
    }

    func testBothOccupiedByFilesIsNameCollision() throws {
        try makeFile("Tasks")
        try makeFile("Logs")

        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .nameCollision)
    }

    // MARK: - Pinned precedence: any collision wins over the missing cases

    func testCollisionWithTasksOccupiedAndLogsMissingWinsOverMissing() throws {
        // The pinned example: `Tasks` occupied by a file while `Logs/` is
        // missing is `.nameCollision` — the create path must not scaffold
        // `Logs/` around it.
        try makeFile("Tasks")

        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .nameCollision)
    }

    func testCollisionWithLogsOccupiedAndTasksMissingWinsOverMissing() throws {
        try makeFile("Logs")

        XCTAssertEqual(
            VaultStructureValidator.validate(at: root), .nameCollision)
    }
}

/// Tests for the issue #26 folder-name sanitization: the house character
/// policy of `VaultStore.slug(from:)` (#7) — `/`, `:`, control chars → `-`,
/// case- and space-preserving, trailing dots/spaces trimmed — WITHOUT the
/// slug rule's `.md` suffix and `untitled` fallback (empty → typed error).
final class VaultFolderNameSanitizerTests: XCTestCase {

    // MARK: - Case/space preservation (no slug-casing)

    func testDefaultNamePassesThroughWithSpacesAndCase() {
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("Focus Tracker"), "Focus Tracker")
        XCTAssertEqual(
            try VaultFolderNameSanitizer.sanitize("MIXED Case Name"), "MIXED Case Name")
    }

    // MARK: - Unsafe characters → '-'

    func testSlashAndColonBecomeHyphens() {
        XCTAssertEqual(
            try VaultFolderNameSanitizer.sanitize("Read/Deep:Work"), "Read-Deep-Work")
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("a/b/c"), "a-b-c")
    }

    func testControlCharactersBecomeHyphens() {
        // U+0000–U+001F and U+007F.
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("A\u{1}B"), "A-B")
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("A\u{1F}B"), "A-B")
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("A\u{7F}B"), "A-B")
    }

    // MARK: - Trailing dots/spaces trimmed

    func testTrailingDotsAndSpacesAreTrimmed() {
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("Vault..."), "Vault")
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("Name  "), "Name")
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("Name . . "), "Name")
        // Only TRAILING dots/spaces are trimmed — a leading space stays.
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize(" My Vault "), " My Vault")
    }

    // MARK: - NOT carried over from the slug rule

    func testNoMdSuffixAndNoUntitledFallback() {
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("Notes"), "Notes")
        // `/`/`:`/control chars become `-`, so they never empty the name —
        // unlike the slug rule, there is no `untitled` fallback.
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize("///"), "---")
        XCTAssertEqual(try VaultFolderNameSanitizer.sanitize(":\u{7F}"), "--")
    }

    // MARK: - Empty after sanitize → typed error

    func testEmptyNameThrowsEmptyAfterSanitize() {
        XCTAssertThrowsError(try VaultFolderNameSanitizer.sanitize("")) { error in
            XCTAssertEqual(
                error as? VaultFolderNameSanitizer.SanitizationError,
                .emptyAfterSanitize)
        }
    }

    func testOnlyDotsAndSpacesThrowEmptyAfterSanitize() {
        for raw in ["   ", " . ", "...", " . . . "] {
            XCTAssertThrowsError(try VaultFolderNameSanitizer.sanitize(raw)) { error in
                XCTAssertEqual(
                    error as? VaultFolderNameSanitizer.SanitizationError,
                    .emptyAfterSanitize, "raw: \(raw)")
            }
        }
    }

    // MARK: - Determinism

    func testSanitizationIsDeterministic() throws {
        let raw = " Focus/Tracker: One\u{1F} "
        let first = try VaultFolderNameSanitizer.sanitize(raw)
        let second = try VaultFolderNameSanitizer.sanitize(raw)
        XCTAssertEqual(first, second)
        // Leading space kept (only trailing is trimmed), `/`/`:`/control
        // → '-', trailing space trimmed.
        XCTAssertEqual(first, " Focus-Tracker- One-")
    }
}
