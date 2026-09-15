import XCTest
@testable import FocusTracker

// The #21 nested types used below; file-local aliases keep it readable.
private typealias SessionContext = AppModel.SessionContext

// NOTE (issues #21/#28 — honest AppKit reality): the real `NSPanel`
// floating / always-on-top / non-activating / user-resize-drag behavior is
// **not unit-testable** — this suite covers everything around it: the pure
// positioning/frame math (`MiniTimerWindowLayout`, #21), the resize-clamp +
// countdown-scale helpers and the `AppModel` mini-mode transitions
// (collapse ↔ restore with the session untouched, and the end-from-mini
// path). Manual verification of the actual floating/focus/resize-drag feel
// and the no-clip check at the pinned minimum is deferred to the
// #24/#25 end-to-end verification passes. The mini's countdown derivation
// itself reuses `TimerDisplayState.derive` unchanged (no mini-specific pure
// logic was added), so its behavior stays pinned by the existing
// `TimerDisplayTests` — extended with the frame and resize math here.

/// Pure positioning/frame math for the compact window (issue #21 criterion 6):
/// `MiniTimerWindowLayout.defaultTopRightFrame` — tested without any AppKit
/// window or screen.
final class MiniTimerWindowLayoutTests: XCTestCase {

    func testDefaultFramePinsToTopRightWithMargin() {
        let frame = MiniTimerWindowLayout.defaultTopRightFrame(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))

        // Exactly `margin` in from the visible frame's top-right corner
        // (AppKit's bottom-left-origin coordinates: maxY is the top edge).
        XCTAssertEqual(frame.maxX, 1440 - MiniTimerWindowLayout.screenMargin)
        XCTAssertEqual(frame.maxY, 900 - MiniTimerWindowLayout.screenMargin)
        // In the top-right quadrant, as PRD §11 intends.
        XCTAssertGreaterThan(frame.minX, 1440 / 2)
        XCTAssertGreaterThan(frame.minY, 900 / 2)
        // Exactly the pinned content size.
        XCTAssertEqual(frame.width, MiniTimerWindowLayout.contentSize.width)
        XCTAssertEqual(frame.height, MiniTimerWindowLayout.contentSize.height)
    }

    func testDefaultFrameOffsetsInsideNonZeroOriginScreen() {
        // A secondary screen whose visible frame does not start at (0, 0):
        // the frame must stay relative to that screen's own bounds.
        let visible = CGRect(x: 2000, y: 100, width: 1920, height: 1080)
        let frame = MiniTimerWindowLayout.defaultTopRightFrame(visibleFrame: visible)

        XCTAssertEqual(frame.maxX, visible.maxX - MiniTimerWindowLayout.screenMargin)
        XCTAssertEqual(frame.maxY, visible.maxY - MiniTimerWindowLayout.screenMargin)
        XCTAssertEqual(frame.minX, visible.maxX - frame.width - MiniTimerWindowLayout.screenMargin)
        XCTAssertEqual(
            frame.minY, visible.maxY - frame.height - MiniTimerWindowLayout.screenMargin)
    }

    func testTinyScreenClampsInsideVisibleFrame() {
        // A visible frame with less margin slack than the panel needs: the
        // clamp keeps the margin (origin) over the top-right alignment while
        // the panel still fits fully inside (real displays always offer far
        // more room than the 260×112 panel).
        let screen = CGRect(x: 0, y: 0, width: 280, height: 130)
        let frame = MiniTimerWindowLayout.defaultTopRightFrame(
            visibleFrame: screen,
            contentSize: CGSize(width: 260, height: 112),
            margin: 16)

        XCTAssertEqual(frame.minX, 16)
        XCTAssertEqual(frame.minY, 16)
        XCTAssertEqual(frame.width, 260)
        XCTAssertEqual(frame.height, 112)
        XCTAssertTrue(screen.contains(frame))
    }

    func testExplicitContentSizeAndMarginOverride() {
        let frame = MiniTimerWindowLayout.defaultTopRightFrame(
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            contentSize: CGSize(width: 200, height: 80),
            margin: 5)

        XCTAssertEqual(CGRect(
            x: 800 - 200 - 5, y: 600 - 80 - 5, width: 200, height: 80), frame)
    }
}

/// Resize-constraint helpers for the user-resizable compact window (issue #28):
/// the pinned min/max bounds and the pure clamp + countdown-font-scale
/// math. The AppKit enforcement on live edge-drags is not unit-testable;
/// these tests pin the logic the panel is configured from (and which the
/// view's adaptive font relies on). The physical drag-body-vs-drag-edge
/// feel and the visual check at the pinned minimum stay #25's manual pass
/// (TCC-deferred, honestly noted).
final class MiniTimerResizeTests: XCTestCase {

    // MARK: - Pinned bounds (issue #28 criterion 2)

    func testBoundsStayInsideTheSuggestedEnvelope() {
        // The issue's suggested floor/ceiling: min ≥ 200×80, max ≤ 520×240.
        XCTAssertGreaterThanOrEqual(
            MiniTimerWindowLayout.contentMinSize.width, 200)
        XCTAssertGreaterThanOrEqual(
            MiniTimerWindowLayout.contentMinSize.height, 80)
        XCTAssertLessThanOrEqual(
            MiniTimerWindowLayout.contentMaxSize.width, 520)
        XCTAssertLessThanOrEqual(
            MiniTimerWindowLayout.contentMaxSize.height, 240)
    }

    func testBoundsBracketTheDefaultContentSize() {
        // The #21 default must remain reachable: min ≤ default ≤ max per
        // axis (a min above the default would grow the panel on show).
        XCTAssertLessThanOrEqual(
            MiniTimerWindowLayout.contentMinSize.width,
            MiniTimerWindowLayout.contentSize.width)
        XCTAssertLessThanOrEqual(
            MiniTimerWindowLayout.contentMinSize.height,
            MiniTimerWindowLayout.contentSize.height)
        XCTAssertGreaterThanOrEqual(
            MiniTimerWindowLayout.contentMaxSize.width,
            MiniTimerWindowLayout.contentSize.width)
        XCTAssertGreaterThanOrEqual(
            MiniTimerWindowLayout.contentMaxSize.height,
            MiniTimerWindowLayout.contentSize.height)
    }

    // MARK: - clampedContentSize

    func testClampPassesSizesInsideBoundsThrough() {
        XCTAssertEqual(
            MiniTimerWindowLayout.clampedContentSize(
                MiniTimerWindowLayout.contentSize),
            MiniTimerWindowLayout.contentSize)
        let mid = CGSize(width: 300, height: 150)
        XCTAssertEqual(
            MiniTimerWindowLayout.clampedContentSize(mid), mid)
    }

    func testClampCollapsesBelowMinToMin() {
        XCTAssertEqual(
            MiniTimerWindowLayout.clampedContentSize(
                CGSize(width: 100, height: 40)),
            MiniTimerWindowLayout.contentMinSize)
    }

    func testClampCapsAboveMaxToMax() {
        XCTAssertEqual(
            MiniTimerWindowLayout.clampedContentSize(
                CGSize(width: 900, height: 500)),
            MiniTimerWindowLayout.contentMaxSize)
    }

    func testClampIsIndependentPerAxis() {
        // Too narrow but too tall → min width, max width's height stays.
        XCTAssertEqual(
            MiniTimerWindowLayout.clampedContentSize(
                CGSize(width: 150, height: 400)),
            CGSize(
                width: MiniTimerWindowLayout.contentMinSize.width,
                height: MiniTimerWindowLayout.contentMaxSize.height))
        // Wide but flat → max width, min height.
        XCTAssertEqual(
            MiniTimerWindowLayout.clampedContentSize(
                CGSize(width: 700, height: 50)),
            CGSize(
                width: MiniTimerWindowLayout.contentMaxSize.width,
                height: MiniTimerWindowLayout.contentMinSize.height))
    }

    // MARK: - countdownFontSize(forContentSize:)

    func testCountdownFontAtDefaultIsTheDesignToken() {
        XCTAssertEqual(
            MiniTimerWindowLayout.countdownFontSize(
                forContentSize: MiniTimerWindowLayout.contentSize),
            DesignTokens.miniCountdownSize)
    }

    func testCountdownFontScalesDownToTheMinBound() {
        // At the pinned min the helper's smallest step applies; between the
        // min and default heights it shrinks monotonically.
        XCTAssertEqual(
            MiniTimerWindowLayout.countdownFontSize(
                forContentSize: MiniTimerWindowLayout.contentMinSize),
            MiniTimerWindowLayout.countdownMinFontSize)
        let quarter = MiniTimerWindowLayout.countdownMinFontSize
        let base = DesignTokens.miniCountdownSize
        let mid = CGSize(
            width: MiniTimerWindowLayout.contentSize.width,
            height: (MiniTimerWindowLayout.contentMinSize.height
                + MiniTimerWindowLayout.contentSize.height) / 2)
        let fontSize = MiniTimerWindowLayout.countdownFontSize(forContentSize: mid)
        XCTAssertGreaterThan(fontSize, quarter)
        XCTAssertLessThan(fontSize, base)
    }

    func testCountdownFontScalesUpToTheMaxBound() {
        XCTAssertEqual(
            MiniTimerWindowLayout.countdownFontSize(
                forContentSize: MiniTimerWindowLayout.contentMaxSize),
            MiniTimerWindowLayout.countdownMaxFontSize)
        let base = DesignTokens.miniCountdownSize
        let mid = CGSize(
            width: MiniTimerWindowLayout.contentSize.width,
            height: (MiniTimerWindowLayout.contentSize.height
                + MiniTimerWindowLayout.contentMaxSize.height) / 2)
        let fontSize = MiniTimerWindowLayout.countdownFontSize(forContentSize: mid)
        XCTAssertGreaterThan(fontSize, base)
        XCTAssertLessThan(fontSize, MiniTimerWindowLayout.countdownMaxFontSize)
    }

    func testCountdownFontClampsOutOfRangeHeights() {
        XCTAssertEqual(
            MiniTimerWindowLayout.countdownFontSize(
                forContentSize: CGSize(width: 10, height: 10)),
            MiniTimerWindowLayout.countdownMinFontSize)
        XCTAssertEqual(
            MiniTimerWindowLayout.countdownFontSize(
                forContentSize: CGSize(width: 2000, height: 2000)),
            MiniTimerWindowLayout.countdownMaxFontSize)
    }

    func testCountdownFontIsHeightDrivenOnly() {
        // Same height, different widths → same size (the countdown is the
        // panel's vertical anchor; documented as height-driven).
        let narrow = MiniTimerWindowLayout.countdownFontSize(
            forContentSize: CGSize(
                width: MiniTimerWindowLayout.contentMinSize.width, height: 112))
        let wide = MiniTimerWindowLayout.countdownFontSize(
            forContentSize: CGSize(
                width: MiniTimerWindowLayout.contentMaxSize.width, height: 112))
        XCTAssertEqual(narrow, wide)
        XCTAssertEqual(narrow, DesignTokens.miniCountdownSize)
    }
}

/// `AppModel` mini-mode transitions (issue #21 criteria 3–4): collapse ↔
/// restore while a session is running — the session state untouched and the
/// phase consistent (`.timerView`) both ways — and the end-from-mini path
/// (endSession → idle + the #22 `.endingSession` phase + mini state
/// cleared). Temp-dir fixture copy per the established pattern; the
/// FakeClock starts at monotonic 0 so the "session untouched" asserts are
/// exact.
@MainActor
final class AppModelMiniTimerTests: XCTestCase {

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
            .appendingPathComponent("MiniTimerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "MiniTimerTests-\(UUID().uuidString)"
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

    /// The #29 `.endingSession` phase carries the end-instant snapshot
    /// between the result and the context; these pre-#29 assertions match
    /// result + context and verify the snapshot's session identity (its
    /// exact fields are pinned by the #29 tests).
    private func assertEndingPhase(
        _ phase: AppModel.AppPhase, result: FocusSessionResult,
        context: SessionContext,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .endingSession(let retained, let snapshot, let retainedContext) = phase else {
            XCTFail("expected .endingSession(...), got \(phase)", file: file, line: line)
            return
        }
        XCTAssertEqual(retained, result, file: file, line: line)
        XCTAssertEqual(retainedContext, context, file: file, line: line)
        XCTAssertEqual(
            snapshot.sessionID, result.sessionID, "snapshot identity",
            file: file, line: line)
    }

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

    /// Starts a session and asserts the `.started` shape (sessionState
    /// `.running`, phase `.timerView`).
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
        XCTAssertFalse(model.isMiniTimerActive, "mini mode starts off")
        return context
    }

    private struct TestFailure: Error {}

    /// Resolves the #22 `.endingSession` phase left open by `endSession()`
    /// (a No answer, no notes) and the #23 post-session choice (Start Next
    /// Session — now the #34 direct `.sessionStart` phase) so a next session
    /// can start (§12.5, issue #23 criterion 4).
    private func submitEndingForm(on model: AppModel) async throws {
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 3
        form.energyRating = 3
        let outcome = try await model.submitEndOfSession(form)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .sessionStart)
    }

    // MARK: - Collapse while running (issue #21 criterion 3)

    func testCollapseWhileRunningSetsFlagAndLeavesSessionAndPhaseUntouched() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)
        let remainingBefore = model.remainingSeconds
        let focusedBefore = model.focusedSeconds

        model.collapseToMiniTimer()

        XCTAssertTrue(model.isMiniTimerActive, "mini flag on")
        // The phase stays `.timerView` (pinned flag-beside-phase choice) with
        // the exact same context — no content torn down.
        XCTAssertEqual(model.appPhase, .timerView(context))
        // Session untouched: same state, same clock-frozen readings.
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertTrue(model.isSessionActive)
        XCTAssertEqual(model.remainingSeconds, remainingBefore)
        XCTAssertEqual(model.focusedSeconds, focusedBefore)
        // The on-disk snapshot still describes the running session.
        let snapshot = try FileActiveSessionPersistence(directory: persistenceDirectory)
            .load()
        XCTAssertEqual(snapshot?.taskID, taskID)
    }

    func testCollapseRefusedWhileIdle() async throws {
        let model = await makeConfiguredModel()

        model.collapseToMiniTimer()

        XCTAssertFalse(model.isMiniTimerActive, "no compact mode when idle (criterion 5)")
        XCTAssertEqual(model.appPhase, .tasksView)
        XCTAssertEqual(model.sessionState, .idle)
    }

    // MARK: - Pause/Resume through mini (issue #21 criteria 2–3)

    func testPauseFromMiniFreezesAndResumeUnfreezesWithFlagAndPhaseStable() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)

        model.collapseToMiniTimer()
        try model.pauseSession()

        XCTAssertTrue(model.isMiniTimerActive, "mini mode survives pausing")
        XCTAssertEqual(model.appPhase, .timerView(context))
        XCTAssertEqual(model.sessionState, .paused)
        // Paused freezes the remaining seconds (#12 semantics).
        XCTAssertEqual(model.remainingSeconds, 1500)
        let frozenRemaining = model.remainingSeconds

        try model.resumeSession()

        XCTAssertTrue(model.isMiniTimerActive, "mini mode survives resuming")
        XCTAssertEqual(model.appPhase, .timerView(context))
        XCTAssertEqual(model.sessionState, .running)
        XCTAssertEqual(model.remainingSeconds, frozenRemaining, "clock untouched")
    }

    // MARK: - Restore round trip (issue #21 criterion 3)

    func testRestoreRoundTripReturnsToFullTimerWithSessionUntouched() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)
        let remainingBefore = model.remainingSeconds
        let identity = ObjectIdentifier(model)
        let initializationCount = AppModel.initializationCount
        let bootstrapCount = AppModel.bootstrapCount

        for cycle in 1...3 {
            model.collapseToMiniTimer()
            XCTAssertTrue(model.isMiniTimerActive, "cycle \(cycle): compact")
            model.restoreFromMiniTimer()

            XCTAssertFalse(model.isMiniTimerActive, "cycle \(cycle): full")
            XCTAssertEqual(model.appPhase, .timerView(context), "cycle \(cycle): no recovery")
            XCTAssertEqual(model.sessionState, .running)
            XCTAssertTrue(model.isSessionActive)
            XCTAssertEqual(model.remainingSeconds, remainingBefore)
            XCTAssertEqual(ObjectIdentifier(model), identity)
            XCTAssertEqual(AppModel.initializationCount, initializationCount)
            XCTAssertEqual(AppModel.bootstrapCount, bootstrapCount)
        }
    }

    func testRestoreWhenNotCollapsedIsTypedNoOp() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        _ = try await startRunningSession(on: model, taskID: taskID)

        model.restoreFromMiniTimer()

        XCTAssertFalse(model.isMiniTimerActive)
        XCTAssertEqual(model.sessionState, .running, "session untouched")
    }

    // MARK: - End from mini (issue #21 criterion 4 + #22 end flow)

    func testEndFromMiniClearsMiniStateEntersEndingPhaseAndGoesIdle() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)
        model.recordSessionNumberToday(3)
        model.collapseToMiniTimer()
        XCTAssertTrue(model.isMiniTimerActive)

        let result = try model.endSession()

        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertFalse(model.isSessionActive)
        // #22: the confirm enters the REQUIRED `.endingSession` phase (the
        // modal over the restored main window) — not a direct return to
        // Tasks — holding the result plus the session context.
        assertEndingPhase(model.appPhase, result: result, context: context)
        XCTAssertTrue(model.isMiniTimerActive == false, "mini cleared")
        XCTAssertNil(model.sessionNumberToday, "stale snapshot cleared")
        // The on-disk active-session snapshot was cleared by the end.
        let snapshot = try FileActiveSessionPersistence(directory: persistenceDirectory)
            .load()
        XCTAssertNil(snapshot)
    }

    func testEndFromFullAfterRestoreAlsoClearsMiniState() async throws {
        let taskID = UUID()
        try writeTaskFile("Alpha task", id: taskID)
        let model = await makeConfiguredModel()
        let context = try await startRunningSession(on: model, taskID: taskID)

        // Collapse → restore → end from the full view: the flag (already
        // off) stays off and the phase lands on the #22 ending state.
        model.collapseToMiniTimer()
        model.restoreFromMiniTimer()
        let result = try model.endSession()

        XCTAssertFalse(model.isMiniTimerActive)
        assertEndingPhase(model.appPhase, result: result, context: context)
        XCTAssertEqual(model.sessionState, .idle)
    }

    // MARK: - Session-number snapshot plumbing (issue #21 criterion 2)

    func testSessionNumberSnapshotIsLiftedAndResetPerSession() async throws {
        let firstTask = UUID()
        let secondTask = UUID()
        try writeTaskFile("Alpha task", id: firstTask)
        try writeTaskFile("Beta task", id: secondTask)
        let model = await makeConfiguredModel()

        // Session 1: the #20 snapshot is recorded and readable (the mini
        // view's source of truth — no refetch).
        _ = try await startRunningSession(on: model, taskID: firstTask)
        XCTAssertNil(model.sessionNumberToday, "fresh session starts unrecorded")
        model.recordSessionNumberToday(4)
        XCTAssertEqual(model.sessionNumberToday, 4)

        // Ending clears it; session 2 starts unrecorded again (a fresh
        // fetch, never a stale number). The required #22 wrap-up is
        // submitted between the two sessions (§12.5).
        _ = try model.endSession()
        XCTAssertNil(model.sessionNumberToday)
        try await submitEndingForm(on: model)

        _ = try await startRunningSession(on: model, taskID: secondTask)
        XCTAssertNil(model.sessionNumberToday, "new session re-fetches")
        model.recordSessionNumberToday(1)
        XCTAssertEqual(model.sessionNumberToday, 1)
        _ = try model.endSession()
        XCTAssertNil(model.sessionNumberToday)
    }
}
