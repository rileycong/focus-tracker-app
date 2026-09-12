import XCTest
@testable import FocusTracker

/// Tests for the #13 pure recovery decision (`ActiveSessionRecovery.decide`)
/// over a `load()` outcome — no I/O anywhere in the decision itself.
final class ActiveSessionRecoveryTests: XCTestCase {

    private struct UnrelatedStorageError: Error, Equatable {}

    private func snapshot() -> ActiveSessionSnapshot {
        ActiveSessionSnapshot(
            sessionID: UUID(),
            taskID: UUID(),
            duration: 1500,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 600,
            accumulatedPausedSeconds: 0,
            pauseCount: 0,
            isPaused: false,
            segmentStartMonotonic: 600)
    }

    // MARK: - The three pinned outcomes (criterion 4)

    func testLoadedSnapshotDecidesResume() {
        let loaded = snapshot()
        XCTAssertEqual(
            ActiveSessionRecovery.decide(.success(loaded)),
            .resume(loaded),
            "snapshot → resume (rehydrate to exact state)")
    }

    func testNilOutcomeDecidesIdleStart() {
        XCTAssertEqual(
            ActiveSessionRecovery.decide(.success(nil)),
            .idle,
            "no snapshot → normal idle start")
    }

    func testCorruptOutcomeSurfacesQuarantinePathAndTreatsSnapshotAsAbsent() {
        let outcome: Result<ActiveSessionSnapshot?, Error> = .failure(
            ActiveSessionPersistenceError.corruptSnapshot(path: "/q/active-session.json.corrupt"))
        XCTAssertEqual(
            ActiveSessionRecovery.decide(outcome),
            .corruptSnapshot(path: "/q/active-session.json.corrupt"),
            "corrupt → typed error surfaced, snapshot treated as absent")
    }

    func testUnrelatedLoadFailureIsSurfacedAndTreatedAsAbsent() {
        let outcome: Result<ActiveSessionSnapshot?, Error> = .failure(UnrelatedStorageError())
        XCTAssertEqual(
            ActiveSessionRecovery.decide(outcome),
            .corruptSnapshot(path: nil),
            "any load failure is surfaced, never silently treated as a clean idle start")
    }

    // MARK: - Integration with the load path (outcome produced by real load)

    func testDecisionOverRealPersistenceOutcomes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ActiveSessionRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let persistence = FileActiveSessionPersistence(directory: storage)

        // Missing → idle.
        XCTAssertEqual(
            ActiveSessionRecovery.decide(Result { try persistence.load() }), .idle)

        // Snapshot → resume.
        let loaded = snapshot()
        try persistence.save(loaded)
        XCTAssertEqual(
            ActiveSessionRecovery.decide(Result { try persistence.load() }), .resume(loaded))

        // Corrupt → surfaced with the quarantine path (file already moved).
        let corrupt = storage.appendingPathComponent("active-session.json")
        try Data("garbage".utf8).write(to: corrupt)
        let outcome = Result<ActiveSessionSnapshot?, Error> { try persistence.load() }
        guard case .corruptSnapshot(.some(let path)) = ActiveSessionRecovery.decide(outcome) else {
            return XCTFail("expected corruptSnapshot, got \(ActiveSessionRecovery.decide(outcome))")
        }
        XCTAssertTrue(path.hasSuffix("active-session.json.corrupt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
