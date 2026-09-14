import XCTest
@testable import FocusTracker

// The #19 nested type used below; file-local alias keeps it readable.
private typealias SessionContext = AppModel.SessionContext

/// The `AppModel` mini-presentation state machine around the #31 fix:
/// `miniTimerPresentationEpoch` — the re-delivery counter that makes every
/// accepted collapse/restore request deliver a sync run to the app shell's
/// level-driven `syncMiniPanel`.
///
/// # Why this is the regression that matters (issue #31 root cause)
/// The pre-#31 sync was edge-driven on the flag itself. A collapsed session
/// whose panel presentation diverged from the flag (panel lost/dismissed
/// while `isMiniTimerActive` stayed on — the user's forensically-dumped
/// stuck instance: window back on screen, no panel in the window server,
/// flag stranded) could never recover: the user's repeated Mini click set
/// `true→true`, which fires no edge, so no sync ever ran again — the
/// reported "second attempt dead". The epoch bumps on EVERY accepted
/// request (even a no-change repeat), so every click re-delivers a sync
/// run and the presentation self-heals; these tests pin that contract at
/// the state-machine level (the AppKit window work itself is verified by
/// the manual pass — TCC-deferred, issue #25/#24).
///
/// Same fixture/temp-dir/FakeClock seams as `AppModelMiniTimerTests` (#21).
@MainActor
final class AppModelMiniTimerEpochTests: XCTestCase {

    // MARK: - Test doubles (same seams as the #13/#14/#19 tests)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private final class ManualTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
    }

    // MARK: - Fixture access

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private var root: URL!
    private var vaultURL: URL!
    private var persistenceDirectory: URL!
    private var suiteName: String!
    private var settings: AppSettings!
    private var clock: FakeClock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MiniTimerEpochTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "MiniTimerEpochTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
        clock = FakeClock()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let model = AppModel(
            settings: settings, persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(), sessionClock: clock)
        await model.bootstrap()
        return model
    }

    /// Writes a To Do task file, mirroring the fixture schema's exact shape.
    private func writeTaskFile(_ title: String, id: UUID) throws {
        let lines = [
            "---",
            "id: \(id.uuidString)",
            "title: \(title)",
            "status: To Do",
            "categories:",
            "  - Testing",
            "---",
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: vaultURL.appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent("\(title).md"),
            atomically: true, encoding: .utf8)
    }

    /// Starts a session and asserts the `.started` shape.
    private func startRunningSession(on model: AppModel, taskID: UUID) async throws
        -> SessionContext
    {
        let outcome = try await model.startSession(taskID: taskID)
        guard case .started(let context) = outcome else {
            XCTFail("expected .started(...), got \(outcome)")
            throw TestFailure()
        }
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertEqual(model.appPhase, .timerView(context))
        return context
    }

    private struct TestFailure: Error {}

    /// Resolves the #22 `.endingSession` phase (No answer) and the #23
    /// post-session choice so a next session can start.
    private func submitEndingForm(on model: AppModel) async throws {
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 3
        form.energyRating = 3
        let outcome = try await model.submitEndOfSession(form)
        XCTAssertEqual(outcome, .success)
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .sessionStart)
    }

    // MARK: - Epoch basics (issue #31)

    func testEpochStartsAtZeroAndRefusedCollapseDoesNotBump() async throws {
        let model = await makeConfiguredModel()
        XCTAssertEqual(model.miniTimerPresentationEpoch, 0, "no requests yet")

        // Idle: no session, phase .tasksView — both guards refuse.
        model.collapseToMiniTimer()
        XCTAssertFalse(model.isMiniTimerActive)
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, 0,
            "a refused request must not deliver a sync run")
        model.restoreFromMiniTimer()
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, 0,
            "a typed no-op restore must not deliver a sync run")
    }

    func testAcceptedCollapseBumpsEpochExactlyOnce() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)

        model.collapseToMiniTimer()

        XCTAssertTrue(model.isMiniTimerActive)
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, 1,
            "one accepted collapse = one sync delivery")
    }

    // MARK: - The #31 deadlock: a repeated click must re-deliver

    func testRepeatedCollapseWhileAlreadyCollapsedStillBumpsEpoch() async throws {
        // THE reported failure: first collapse strands the presentation
        // (panel lost while the flag stays on), then the user's second Mini
        // click was a silent no-op — no sync re-delivery, mini mode dead
        // until relaunch. The epoch contract: an accepted collapse bumps
        // EVEN when the flag does not change, so the level-driven sync runs
        // again and re-asserts the panel (the AppKit half is the manual
        // #24/#25 pass; here the state machine's re-delivery guarantee).
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)

        model.collapseToMiniTimer()
        XCTAssertTrue(model.isMiniTimerActive)
        XCTAssertEqual(model.miniTimerPresentationEpoch, 1)

        // The user's second click (flag already on — pre-#31 this fired
        // nothing at all).
        model.collapseToMiniTimer()

        XCTAssertTrue(
            model.isMiniTimerActive,
            "still collapsed — the repeat must not un-collapse")
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, 2,
            "the repeated click re-delivers a sync run (the #31 fix)")
    }

    // MARK: - Repeatable cycles (issue #31 acceptance criterion 3)

    func testCollapseRestoreCyclesAreRepeatableWithMonotonicEpoch() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)
        let remainingBefore = model.remainingSeconds

        for cycle in 1...3 {
            model.collapseToMiniTimer()
            XCTAssertTrue(model.isMiniTimerActive, "cycle \(cycle): collapsed")
            XCTAssertEqual(model.appPhase, .timerView(context))
            XCTAssertEqual(model.sessionState, .running)
            XCTAssertEqual(
                model.miniTimerPresentationEpoch, 2 * cycle - 1,
                "cycle \(cycle): collapse delivered exactly one sync run")

            model.restoreFromMiniTimer()
            XCTAssertFalse(model.isMiniTimerActive, "cycle \(cycle): restored")
            XCTAssertEqual(model.appPhase, .timerView(context))
            XCTAssertEqual(model.sessionState, .running)
            XCTAssertEqual(
                model.miniTimerPresentationEpoch, 2 * cycle,
                "cycle \(cycle): restore delivered exactly one sync run")
        }
        // The session itself is untouched across all cycles.
        XCTAssertTrue(model.isSessionActive)
        XCTAssertEqual(model.remainingSeconds, remainingBefore)
    }

    func testMiniModeWorksAcrossSessionsAfterEndAndRestart() async throws {
        let first = UUID()
        try writeTaskFile("First task", id: first)
        let second = UUID()
        try writeTaskFile("Second task", id: second)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: first)

        model.collapseToMiniTimer()
        _ = try model.endSession()
        // endSession clears the flag; the epoch is untouched (the sync
        // delivery for an end rides the `.endingSession` phase change).
        XCTAssertFalse(model.isMiniTimerActive)
        XCTAssertEqual(model.miniTimerPresentationEpoch, 1)

        try await submitEndingForm(on: model)
        _ = try await startRunningSession(on: model, taskID: second)

        // Collapse on the NEW session must deliver a fresh sync run.
        model.collapseToMiniTimer()
        XCTAssertTrue(model.isMiniTimerActive)
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, 2,
            "the next session's collapse delivers its own sync run")
        model.restoreFromMiniTimer()
        XCTAssertFalse(model.isMiniTimerActive)
        XCTAssertEqual(model.miniTimerPresentationEpoch, 3)
    }

    // MARK: - Epoch stability on unrelated transitions

    func testPauseResumeWhileCollapsedDoesNotBumpEpoch() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        model.collapseToMiniTimer()
        let epochAfterCollapse = model.miniTimerPresentationEpoch

        try model.pauseSession()
        try model.resumeSession()

        XCTAssertTrue(model.isMiniTimerActive)
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, epochAfterCollapse,
            "pause/resume must not re-deliver the mini sync (no #21 edge)")
    }

    func testEndSessionClearsFlagWithoutBumpingEpoch() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)
        model.collapseToMiniTimer()
        XCTAssertEqual(model.miniTimerPresentationEpoch, 1)

        _ = try model.endSession()

        XCTAssertFalse(
            model.isMiniTimerActive,
            "the panel closes on a session end by any path (criterion 5)")
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, 1,
            "the end's sync delivery rides the .endingSession phase change")
    }
}
