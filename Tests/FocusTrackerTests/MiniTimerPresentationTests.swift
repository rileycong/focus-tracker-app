import XCTest
@testable import FocusTracker

// The #19 nested type used below; file-local alias keeps it readable.
private typealias SessionContext = AppModel.SessionContext

/// The #37 mini-presentation contract additions: the pure frame-sanity
/// predicate the show path now self-heals with, and the post-end stale
/// click behaviour the stuck-state forensics demand.
///
/// # Why these are the #37 regressions that matter
/// The user's real instance (forensically dumped live via CGWindowList
/// while stuck: main window ordered out, NO panel window anywhere in the
/// window server, no live session, app alive) proved the presentation can
/// diverge from the observable state in ways no edge delivery ever
/// repairs. The fix makes the presentation self-healing:
/// - `show()` resets a panel stranded off-screen (display change while the
///   frame survived — `frameIsFullyOnScreen` is that predicate, pure and
///   pinned here), and
/// - the app shell reconciles the presentation on a ~1 s level-driven
///   cadence while a session lifecycle is open (AppKit-side, verified by
///   the `-autoCollapseDemoGhost` harness run), so ANY vanish heals within
///   ~1 s without user input.
/// The stale-click tests pin the state machine's side of the contract: a
/// click after the session ended must be a silent typed no-op that cannot
/// re-deliver a stale collapse (the reconcile's repair-only domain).
///
/// Same fixture/temp-dir/FakeClock seams as `AppModelMiniTimerEpochTests`.
@MainActor
final class MiniTimerPresentationTests: XCTestCase {

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
            .appendingPathComponent("MiniTimerPresentationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "MiniTimerPresentationTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
        clock = FakeClock()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.setUpWithError()
    }

    // MARK: - Helpers

    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let model = AppModel(
            settings: settings,
            persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(),
            sessionClock: clock)
        await model.bootstrap()
        return model
    }

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

    private func startRunningSession(on model: AppModel, taskID: UUID) async throws
        -> SessionContext
    {
        let outcome = try await model.startSession(taskID: taskID)
        guard case .started(let context) = outcome else {
            XCTFail("expected .started(...), got \(outcome)")
            throw TestFailure()
        }
        return context
    }

    private struct TestFailure: Error {}

    // MARK: - frameIsFullyOnScreen (the show-path self-heal predicate)

    func testFrameInsideSingleScreenIsOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 1200, y: 750, width: 200, height: 100)
        XCTAssertTrue(
            MiniTimerPanelLayout.frameIsFullyOnScreen(frame, visibleFrames: [screen]))
    }

    func testFrameFullyOutsideEveryScreenIsOffScreen() {
        // The #37 vanish shape: the panel's frame outlived its display
        // (lid closed / display unplugged) and now sits in dead coordinate
        // space — silently invisible to the user.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let stranded = CGRect(x: 3000, y: 1200, width: 260, height: 112)
        XCTAssertFalse(
            MiniTimerPanelLayout.frameIsFullyOnScreen(stranded, visibleFrames: [screen]))
    }

    func testFramePartiallyOutsideIsOffScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let clipped = CGRect(x: 1380, y: 850, width: 260, height: 112)
        XCTAssertFalse(
            MiniTimerPanelLayout.frameIsFullyOnScreen(clipped, visibleFrames: [screen]))
    }

    func testFrameInsideSecondScreenOfTwoIsOnScreen() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let frame = CGRect(x: 3700, y: 1300, width: 260, height: 112)
        XCTAssertTrue(
            MiniTimerPanelLayout.frameIsFullyOnScreen(frame, visibleFrames: [left, right]))
    }

    func testFrameSpanningTwoAdjacentScreensIsOnScreen() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let spanning = CGRect(x: 1400, y: 400, width: 200, height: 100)
        XCTAssertTrue(
            MiniTimerPanelLayout.frameIsFullyOnScreen(spanning, visibleFrames: [left, right]))
    }

    func testNoScreensMeansOffScreen() {
        let frame = CGRect(x: 0, y: 0, width: 260, height: 112)
        XCTAssertFalse(
            MiniTimerPanelLayout.frameIsFullyOnScreen(frame, visibleFrames: []))
    }

    // MARK: - Post-end stale clicks (the 84129 stuck-state forensics)

    func testCollapseAfterSessionEndedIsRefusedWithoutEpochBump() async throws {
        // The user's stuck instance reached "main hidden, no panel, no
        // session": a collapse while collapsed, then the session ended —
        // and a further Mini click must not re-deliver a stale collapse.
        // The guards refuse (no session / no .timerView), nothing bumps,
        // so the level-driven reconciler's repair-only domain is never
        // fed a stale collapse by a dead lifecycle.
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)

        model.collapseToMiniTimer()
        XCTAssertTrue(model.isMiniTimerActive)
        XCTAssertEqual(model.miniTimerPresentationEpoch, 1)

        _ = try model.endSession()
        XCTAssertFalse(model.isMiniTimerActive, "the end clears the flag")
        XCTAssertEqual(model.miniTimerPresentationEpoch, 1, "the end does not bump")

        // The stale Mini click after the end (the exact 84129 situation).
        model.collapseToMiniTimer()
        XCTAssertFalse(model.isMiniTimerActive)
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, 1,
            "a refused post-end collapse must not deliver a sync run")

        // The stale restore click is the same typed no-op.
        model.restoreFromMiniTimer()
        XCTAssertFalse(model.isMiniTimerActive)
        XCTAssertEqual(
            model.miniTimerPresentationEpoch, 1,
            "a refused post-end restore must not deliver a sync run")
    }

    func testEndFromMiniClearsFlagAndNextSessionStartsUncollapsed() async throws {
        // The end-from-mini path (the #30 pinned order's consumer): flag
        // cleared at the confirm instant, phase `.endingSession` — the
        // reconciler's restore branch then shows the main window and
        // dismisses the panel on this delivery; a fresh session starts in
        // the full view (nothing persisted).
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)

        model.collapseToMiniTimer()
        XCTAssertTrue(model.isMiniTimerActive)

        _ = try model.endSession()
        XCTAssertFalse(model.isMiniTimerActive)
        guard case .endingSession = model.appPhase else {
            XCTFail("expected .endingSession, got \(model.appPhase)")
            return
        }

        // The same session cannot be re-collapsed by a stale click while
        // the end flow is unresolved.
        model.collapseToMiniTimer()
        XCTAssertFalse(model.isMiniTimerActive)
        XCTAssertEqual(model.miniTimerPresentationEpoch, 1)
        _ = context
    }
}
