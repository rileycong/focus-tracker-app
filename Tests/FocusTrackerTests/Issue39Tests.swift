import XCTest
import AppKit
@testable import FocusTracker

final class Issue39Tests: XCTestCase {
    private final class Clock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private final class Persistence: ActiveSessionPersistence, @unchecked Sendable {
        var snapshot: ActiveSessionSnapshot?
        func save(_ snapshot: ActiveSessionSnapshot) throws { self.snapshot = snapshot }
        func load() throws -> ActiveSessionSnapshot? { snapshot }
        func clear() throws { snapshot = nil }
    }

    private final class Scheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        var interval: TimeInterval?
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {
            self.interval = interval
        }
        func cancel() { interval = nil }
    }

    @MainActor
    func testTerminationDelegateSavesExactQuitSnapshotAndRemaining() throws {
        let clock = Clock()
        let persistence = Persistence()
        let scheduler = Scheduler()
        let coordinator = ActiveSessionCoordinator(
            engine: FocusSessionEngine(clock: clock),
            persistence: persistence,
            scheduler: scheduler,
            autosaveInterval: AppModel.autosaveIntervalSeconds)
        try coordinator.start(taskID: UUID(), duration: 120)
        clock.monotonicSeconds = 30.75
        clock.wallClockNow = clock.wallClockNow.addingTimeInterval(30.75)

        let delegate = FocusTrackerAppDelegate()
        delegate.snapshotSave = { coordinator.saveSnapshotForTermination() }
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification))

        let snapshot = try XCTUnwrap(persistence.snapshot)
        XCTAssertEqual(snapshot.accumulatedFocusedSeconds, 30.75, accuracy: 1e-9)
        XCTAssertEqual(snapshot.duration - snapshot.accumulatedFocusedSeconds, 89.25)
        XCTAssertEqual(coordinator.remainingSeconds(at: clock.monotonicSeconds), 89)
        XCTAssertEqual(scheduler.interval, 1, "hard-crash loss is bounded to one second")

        let recoveryClock = Clock()
        let recovered = ActiveSessionCoordinator(
            engine: FocusSessionEngine(clock: recoveryClock),
            persistence: Persistence(), scheduler: Scheduler(), autosaveInterval: 1)
        try recovered.restore(from: snapshot)
        XCTAssertEqual(
            recovered.remainingSeconds(at: recoveryClock.monotonicSeconds), 89,
            "relaunch resumes from the exact quit snapshot")
    }

    @MainActor
    func testCompletionBannerDismissCadenceIsThreeSeconds() {
        XCTAssertEqual(TasksView.completionNoticeDuration, .seconds(3))
    }

    func testFullAndMiniShareAlarmShakeTargets() {
        XCTAssertEqual(ExpiryAlarmShakeEffect.targetOffset(isActive: true), 4)
        XCTAssertEqual(ExpiryAlarmShakeEffect.targetOffset(isActive: false), 0)
    }
}
