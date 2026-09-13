import Foundation

// MARK: - Autosave scheduler seam

/// Seam for the periodic autosave tick (issue #13 criterion 3). Production
/// injects a real timer/scheduler; tests inject a manual one and fire the
/// ticks themselves — never a real sleep in tests. The tick is purely a
/// scheduling concern: it carries no session state.
public protocol ActiveSessionTickScheduler: AnyObject, Sendable {
    /// Arranges for `tick` to run after `interval` seconds, replacing any
    /// previously scheduled (still pending) tick. Conformers must not call
    /// back into the coordinator synchronously from inside `schedule`.
    func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void)

    /// Cancels any pending tick; a no-op when none is scheduled.
    func cancel()
}

// MARK: - Coordinator

/// Implements the #13 save-cadence contract over a `FocusSessionEngine` +
/// `ActiveSessionPersistence`, ready for #14 to wire:
///
/// - **save on start, pause, resume** — every lifecycle transition that can
///   open/close a segment refreshes the on-disk snapshot,
/// - **clear on end** — a session that ended and is being logged has no
///   active snapshot,
/// - **periodic autosave** — every `autosaveInterval` seconds while a session
///   is active, driven by the injected `ActiveSessionTickScheduler`; each
///   tick saves and re-arms the next one.
///
/// # Honest loss statement (pinned, issue #13 criterion 3)
/// Time since the last save lives only in memory, so a hard crash loses at
/// most **≤ 1 autosave interval** of focused/paused time. The snapshot's
/// anchor makes recovery from the last save point exact (restoration math on
/// `ActiveSessionSnapshot` / `FocusSessionEngine.restore(from:)`).
///
/// # Error policy (documented)
/// - `start`/`pause`/`resume`: the engine transition happens first; a
///   persistence failure then **throws** so the caller knows the snapshot is
///   stale (the transition stands and the autosave tick has been armed, so
///   later ticks keep retrying).
/// - `end`: the result is computed and the tick cancelled; a `clear()`
///   failure is reported through `onPersistenceError` and the result is
///   still returned — the end result cannot be recreated (the engine closed
///   its lifecycle), so it is never dropped in favor of an error.
/// - autosave tick: failures go through `onPersistenceError` (nil handler →
///   documented ignore; worst case remains the pinned ≤ 1 autosave interval
///   loss) and the tick chain keeps running so the next tick retries.
///
/// # Concurrency
/// `@unchecked Sendable` behind one `NSLock`: the scheduler tick may fire
/// from any queue while lifecycle calls come from the caller's isolation
/// (typically the main actor). Callbacks are invoked **outside** the lock.
public final class ActiveSessionCoordinator: @unchecked Sendable {

    private let lock = NSLock()
    private let persistence: any ActiveSessionPersistence
    private let scheduler: any ActiveSessionTickScheduler
    private let autosaveInterval: TimeInterval
    private var engine: FocusSessionEngine

    /// Receives autosave-tick and end-clear persistence failures. Optional by
    /// design; see the error policy above.
    public let onPersistenceError: (@Sendable (any Error) -> Void)?

    public init(
        engine: FocusSessionEngine = FocusSessionEngine(),
        persistence: any ActiveSessionPersistence,
        scheduler: any ActiveSessionTickScheduler,
        autosaveInterval: TimeInterval,
        onPersistenceError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.engine = engine
        self.persistence = persistence
        self.scheduler = scheduler
        self.autosaveInterval = autosaveInterval
        self.onPersistenceError = onPersistenceError
    }

    // MARK: Lifecycle (cadence: save on start/pause/resume, clear on end)

    /// Starts a session and saves its initial snapshot. Throws the engine's
    /// transition errors or the persistence save error (the session is then
    /// active with the autosave chain armed — see the error policy).
    public func start(
        taskID: UUID,
        duration: TimeInterval = FocusSessionEngine.defaultDurationSeconds
    ) throws {
        try lock.withLock {
            try engine.start(taskID: taskID, duration: duration)
            scheduleNextTickLocked()
            try saveSnapshotLocked()
        }
    }

    /// Pauses and saves. Throws engine or persistence errors (same policy).
    public func pause() throws {
        try lock.withLock {
            try engine.pause()
            scheduleNextTickLocked()
            try saveSnapshotLocked()
        }
    }

    /// Resumes and saves. Throws engine or persistence errors (same policy).
    public func resume() throws {
        try lock.withLock {
            try engine.resume()
            scheduleNextTickLocked()
            try saveSnapshotLocked()
        }
    }

    /// Ends the session and clears the snapshot (no-op success when absent).
    /// A clear failure is reported via `onPersistenceError`; the result is
    /// always returned. Throws the engine's `.noActiveSession`.
    @discardableResult
    public func end() throws -> FocusSessionResult {
        var clearFailure: (any Error)?
        let result: FocusSessionResult = try lock.withLock {
            let result = try engine.end()
            scheduler.cancel()
            do {
                try persistence.clear()
            } catch {
                clearFailure = error
            }
            return result
        }
        if let clearFailure { onPersistenceError?(clearFailure) }
        return result
    }

    // MARK: Recovery (#14 wiring point)

    /// Rehydrates the engine from a snapshot (the #14 recovery flow:
    /// `ActiveSessionRecovery.decide` → `.resume(snapshot)` → this) and
    /// re-arms the autosave chain. The stored snapshot file is deliberately
    /// left untouched — it remains the exact last save point (with its
    /// carried accumulators) until the next cadence save. Throws the
    /// engine's `.sessionAlreadyActive` when a lifecycle is already open.
    public func restore(from snapshot: ActiveSessionSnapshot) throws {
        try lock.withLock {
            try engine.restore(from: snapshot)
            scheduleNextTickLocked()
        }
    }

    // MARK: Periodic autosave (criterion 3)

    /// The periodic autosave hook: saves while a session is active and
    /// re-arms the next tick; does nothing when idle. Driven by the injected
    /// scheduler (never a real sleep in tests). Failures go through
    /// `onPersistenceError` — see the error policy.
    public func autosaveTick() {
        var failure: (any Error)?
        lock.lock()
        if engine.isActive {
            do {
                try saveSnapshotLocked()
            } catch {
                failure = error
            }
            scheduleNextTickLocked()
        }
        lock.unlock()
        if let failure { onPersistenceError?(failure) }
    }

    // MARK: Derived passthroughs (read-only, for #14/#20/#21 consumers)

    /// Whether a session lifecycle is currently open.
    public var isActive: Bool {
        lock.withLock { engine.isActive }
    }

    /// See `FocusSessionEngine.captureSnapshot()` — the pure end-instant
    /// state read (issue #29): `nil` when idle. A READ-ONLY passthrough with
    /// NO persistence side effects: unlike the cadence saves (start/pause/
    /// resume/tick) it never writes the snapshot to disk — the #29 end flow
    /// calls it exactly once, BEFORE `end()` (after end the engine is idle
    /// and this returns `nil` — order matters), to retain the exact
    /// `is_paused`/second-precision-accumulator/pause-count/configured-
    /// `duration` state alongside the `FocusSessionResult` for a possible
    /// Cancel-restore (`restore(from:)` reuses the #13 path unchanged).
    public func captureSnapshot() -> ActiveSessionSnapshot? {
        lock.withLock { engine.captureSnapshot() }
    }

    /// See `FocusSessionEngine.focusedSeconds(at:)`.
    public func focusedSeconds(at now: TimeInterval) -> TimeInterval {
        lock.withLock { engine.focusedSeconds(at: now) }
    }

    /// See `FocusSessionEngine.remainingSeconds(at:)`.
    public func remainingSeconds(at now: TimeInterval) -> Int? {
        lock.withLock { engine.remainingSeconds(at: now) }
    }

    /// See `FocusSessionEngine.progressFraction(at:)`.
    public func progressFraction(at now: TimeInterval) -> Double {
        lock.withLock { engine.progressFraction(at: now) }
    }

    /// See `FocusSessionEngine.isExpired(at:)`.
    public func isExpired(at now: TimeInterval) -> Bool {
        lock.withLock { engine.isExpired(at: now) }
    }

    // MARK: Internals (lock held)

    private func saveSnapshotLocked() throws {
        guard let snapshot = engine.captureSnapshot() else { return }  // idle
        try persistence.save(snapshot)
    }

    private func scheduleNextTickLocked() {
        scheduler.schedule(after: autosaveInterval) { [self] in
            autosaveTick()
        }
    }
}
