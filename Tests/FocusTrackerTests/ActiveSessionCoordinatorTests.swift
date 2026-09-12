import XCTest
@testable import FocusTracker

/// Tests for the #13 save-cadence contract (`ActiveSessionCoordinator`):
/// a spy persistence observes save on start/pause/resume and clear on end;
/// the autosave interval is parameterized via the injected scheduler seam —
/// ticks are fired by the test, never a real sleep.
final class ActiveSessionCoordinatorTests: XCTestCase {

    // MARK: - Test doubles

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(by seconds: TimeInterval) {
            monotonicSeconds += seconds
            wallClockNow = wallClockNow.addingTimeInterval(seconds)
        }
    }

    /// Records every persistence call (including failed attempts, before the
    /// error is thrown) and can inject save/clear failures.
    private final class SpyPersistence: ActiveSessionPersistence, @unchecked Sendable {
        enum Op: Equatable {
            case save(ActiveSessionSnapshot)
            case load
            case clear
        }
        enum FailureMode {
            case none
            case alwaysOnSave
            case failSavesAfter(Int)
            case alwaysOnClear
        }

        private let lock = NSLock()
        private var ops: [Op] = []
        private var stored: ActiveSessionSnapshot?
        private var saveAttempts = 0
        private let failureMode: FailureMode

        init(failureMode: FailureMode = .none) {
            self.failureMode = failureMode
        }

        struct SpyError: Error, Equatable {}

        private func checkSaveFailureLocked() throws {
            switch failureMode {
            case .none:
                return
            case .alwaysOnSave:
                throw SpyError()
            case .failSavesAfter(let allowed):
                if saveAttempts > allowed { throw SpyError() }
            case .alwaysOnClear:
                return
            }
        }

        func save(_ snapshot: ActiveSessionSnapshot) throws {
            lock.withLock {
                ops.append(.save(snapshot))
                saveAttempts += 1
            }
            try lock.withLock {
                try checkSaveFailureLocked()
                stored = snapshot
            }
        }

        func load() throws -> ActiveSessionSnapshot? {
            lock.withLock {
                ops.append(.load)
                return stored
            }
        }

        func clear() throws {
            lock.withLock { ops.append(.clear) }
            if case .alwaysOnClear = failureMode { throw SpyError() }
            lock.withLock { stored = nil }
        }

        var operations: [Op] { lock.withLock { ops } }

        var saveCount: Int {
            lock.withLock { ops.reduce(0) { if case .save = $1 { return $0 + 1 }; return $0 } }
        }

        var clearCount: Int {
            lock.withLock { ops.reduce(0) { if case .clear = $1 { return $0 + 1 }; return $0 } }
        }

        var savedSnapshots: [ActiveSessionSnapshot] {
            lock.withLock {
                ops.compactMap { if case .save(let s) = $0 { return s }; return nil }
            }
        }
    }

    /// Manual scheduler: records the injected interval, lets the test fire
    /// ticks explicitly (the criterion-3 test seam).
    private final class ManualTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable () -> Void)?
        private var interval: TimeInterval?

        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {
            lock.withLock {
                self.interval = interval
                self.pending = tick
            }
        }

        func cancel() {
            lock.withLock {
                self.interval = nil
                self.pending = nil
            }
        }

        var pendingInterval: TimeInterval? { lock.withLock { interval } }

        func firePendingTick() {
            let tick = lock.withLock { pending }
            tick?()
        }
    }

    /// Lock-guarded error recorder for the `onPersistenceError` callback.
    private final class ErrorRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [any Error] = []

        var handler: @Sendable (any Error) -> Void {
            { [self] error in lock.withLock { errors.append(error) } }
        }

        var count: Int { lock.withLock { errors.count } }
    }

    // MARK: - Fixtures and helpers

    private var root: URL!
    private let taskID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ActiveSessionCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makeCoordinator(
        spy: SpyPersistence, scheduler: ManualTickScheduler,
        autosaveInterval: TimeInterval = 30, clock: FakeClock = FakeClock()
    ) -> ActiveSessionCoordinator {
        ActiveSessionCoordinator(
            engine: FocusSessionEngine(clock: clock),
            persistence: spy,
            scheduler: scheduler,
            autosaveInterval: autosaveInterval)
    }

    // MARK: - Cadence: save on start/pause/resume, clear on end (criterion 3, 7)

    func testSavesOnStartPauseResumeAndClearsOnEnd() throws {
        let spy = SpyPersistence()
        let scheduler = ManualTickScheduler()
        let coordinator = makeCoordinator(spy: spy, scheduler: scheduler)

        try coordinator.start(taskID: taskID)
        XCTAssertEqual(spy.saveCount, 1, "save on start")

        try coordinator.pause()
        XCTAssertEqual(spy.saveCount, 2, "save on pause")

        try coordinator.resume()
        XCTAssertEqual(spy.saveCount, 3, "save on resume")

        let result = try coordinator.end()
        XCTAssertEqual(spy.clearCount, 1, "clear on end")
        XCTAssertEqual(spy.saveCount, 3, "no save on end")
        XCTAssertNil(try spy.load(), "cleared: the stored snapshot is gone")
        XCTAssertEqual(result.taskID, taskID)
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(spy.savedSnapshots.allSatisfy { $0.sessionID == result.sessionID })
    }

    // MARK: - Autosave seam (criterion 3, 7)

    func testAutosaveUsesInjectedIntervalAndEachTickSavesAndRearms() throws {
        let spy = SpyPersistence()
        let scheduler = ManualTickScheduler()
        let coordinator = makeCoordinator(spy: spy, scheduler: scheduler, autosaveInterval: 45)

        try coordinator.start(taskID: taskID)
        XCTAssertEqual(scheduler.pendingInterval, 45, "the injected interval is used verbatim")

        scheduler.firePendingTick()
        XCTAssertEqual(spy.operations.count, 2, "tick saves")
        XCTAssertEqual(scheduler.pendingInterval, 45, "tick re-arms the next one")

        scheduler.firePendingTick()
        scheduler.firePendingTick()
        XCTAssertEqual(spy.saveCount, 4)
        XCTAssertEqual(spy.saveCount, spy.operations.count, "only saves, nothing else")
    }

    func testEndCancelsPendingAutosaveTick() throws {
        let spy = SpyPersistence()
        let scheduler = ManualTickScheduler()
        let coordinator = makeCoordinator(spy: spy, scheduler: scheduler)

        try coordinator.start(taskID: taskID)
        scheduler.firePendingTick()
        try coordinator.end()

        XCTAssertNil(scheduler.pendingInterval, "no tick left armed after end")
        let countAfterEnd = spy.operations.count
        scheduler.firePendingTick()
        XCTAssertEqual(spy.operations.count, countAfterEnd, "idle ticks never save")
    }

    func testAutosaveTickWithNoSessionDoesNothing() {
        let spy = SpyPersistence()
        let scheduler = ManualTickScheduler()
        let coordinator = makeCoordinator(spy: spy, scheduler: scheduler)

        coordinator.autosaveTick()  // no session ever started

        XCTAssertEqual(spy.operations, [])
        XCTAssertEqual(scheduler.pendingInterval, nil, "idle: nothing scheduled")
    }

    // MARK: - Recovery wiring (criterion 4 → coordinator)

    func testRestoreRehydratesAndRearmsAutosave() throws {
        // A session from a previous "process": run 10, pause, snapshot.
        let oldClock = FakeClock()
        var oldEngine = FocusSessionEngine(clock: oldClock)
        try oldEngine.start(taskID: taskID, duration: 3600)
        oldClock.advance(by: 600)
        try oldEngine.pause()
        let snapshot = try XCTUnwrap(oldEngine.captureSnapshot())

        let spy = SpyPersistence()
        let scheduler = ManualTickScheduler()
        let coordinator = makeCoordinator(spy: spy, scheduler: scheduler)

        try coordinator.restore(from: snapshot)

        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(scheduler.pendingInterval, 30, "autosave re-armed after restore")

        scheduler.firePendingTick()
        XCTAssertEqual(spy.savedSnapshots.count, 1)
        XCTAssertEqual(spy.savedSnapshots[0].sessionID, snapshot.sessionID,
                       "the tick persists the rehydrated session identity")
        XCTAssertEqual(spy.savedSnapshots[0].accumulatedFocusedSeconds, 600, accuracy: 1e-9)
    }

    // MARK: - Error policy

    func testAutosaveFailureSurfacesViaCallbackAndTickChainKeepsRetrying() throws {
        let spy = SpyPersistence(failureMode: .failSavesAfter(3))
        let scheduler = ManualTickScheduler()
        let recorder = ErrorRecorder()
        let coordinator = ActiveSessionCoordinator(
            engine: FocusSessionEngine(clock: FakeClock()),
            persistence: spy,
            scheduler: scheduler,
            autosaveInterval: 30,
            onPersistenceError: recorder.handler)

        try coordinator.start(taskID: taskID)   // save 1
        try coordinator.pause()                 // save 2
        try coordinator.resume()                // save 3
        XCTAssertEqual(recorder.count, 0)

        scheduler.firePendingTick()             // save 4 → fails
        XCTAssertEqual(recorder.count, 1, "autosave failures surface via callback")
        XCTAssertEqual(scheduler.pendingInterval, 30, "the tick chain still re-arms")

        scheduler.firePendingTick()             // retries and fails again
        XCTAssertEqual(recorder.count, 2)
    }

    func testLifecycleSaveFailurePropagatesAndSessionRemainsActive() throws {
        let spy = SpyPersistence(failureMode: .alwaysOnSave)
        let scheduler = ManualTickScheduler()
        let coordinator = makeCoordinator(spy: spy, scheduler: scheduler)

        XCTAssertThrowsError(try coordinator.start(taskID: taskID)) { error in
            XCTAssertEqual(error as? SpyPersistence.SpyError, SpyPersistence.SpyError())
        }
        // The engine transition stands (documented error policy); the caller
        // knows the snapshot is stale and the tick chain still retries.
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(scheduler.pendingInterval, 30)
    }

    func testEndClearFailureSurfacesViaCallbackAndResultIsStillReturned() throws {
        let spy = SpyPersistence(failureMode: .alwaysOnClear)
        let scheduler = ManualTickScheduler()
        let recorder = ErrorRecorder()
        let coordinator = ActiveSessionCoordinator(
            engine: FocusSessionEngine(clock: FakeClock()),
            persistence: spy,
            scheduler: scheduler,
            autosaveInterval: 30,
            onPersistenceError: recorder.handler)

        try coordinator.start(taskID: taskID)
        let result = try coordinator.end()

        XCTAssertEqual(result.taskID, taskID, "the end result is never dropped")
        XCTAssertEqual(recorder.count, 1, "the clear failure surfaces via callback")
        XCTAssertNil(scheduler.pendingInterval)
        XCTAssertFalse(coordinator.isActive)
    }
}
