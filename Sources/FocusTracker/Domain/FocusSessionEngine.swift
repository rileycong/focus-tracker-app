import Foundation

// MARK: - Clock seam

/// The engine's only source of time (issue #12, PRD §9).
///
/// **Why a dedicated protocol instead of `ContinuousClock` directly:** the
/// engine needs two readings with deliberately different semantics — a
/// monotonic value for every duration computation (interval summation must be
/// immune to wall-clock changes) and the wall-clock `Date` for the
/// `started_at`/`ended_at` log fields (PRD §13). `ContinuousClock` only models
/// the first. Tests inject a fake conformer whose monotonic and wall-clock
/// readings advance independently, which is exactly what makes the
/// clock-change-safety tests possible. The monotonic epoch is arbitrary
/// (production anchors at clock creation): all engine arithmetic is
/// interval-based, so the anchor never leaks.
public protocol FocusSessionClock: Sendable {
    /// Monotonic seconds from an arbitrary anchor; never decreases.
    var monotonicSeconds: TimeInterval { get }
    /// Wall-clock reading — used ONLY for `started_at`/`ended_at` timestamps.
    var wallClockNow: Date { get }
}

/// Production conformer. This is the only place in the timing stack where
/// real time sources are touched — the engine itself never calls `Date()`,
/// `DispatchTime.now()` or `ContinuousClock.now` directly (issue #12).
///
/// The monotonic side deliberately uses `ContinuousClock` (which keeps
/// ticking while the system sleeps) rather than `DispatchTime` /
/// `ProcessInfo.systemUptime` (which freeze during sleep): the pinned v1
/// behavior documented on `FocusSessionEngine` is that an *unpaused*
/// system-sleep gap counts as focused time, which requires a clock that
/// continues through sleep. The anchor is captured at init, so a clock
/// instance must stay stable for the lifetime of the session it serves
/// (callers pass one engine — with its clock — through the whole session).
public struct SystemFocusSessionClock: FocusSessionClock {
    private let anchor: ContinuousClock.Instant

    public init() {
        self.anchor = ContinuousClock.now
    }

    public var monotonicSeconds: TimeInterval {
        let elapsed = ContinuousClock.now - anchor
        let (seconds, attoseconds) = elapsed.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) * 1e-18
    }

    public var wallClockNow: Date {
        Date()
    }
}

// MARK: - Errors

/// Typed, `Equatable` transition errors (issue #12). One case per invalid
/// transition — never a silent no-op (house refusal contract, #9 precedent).
public enum FocusSessionError: Error, Equatable, Sendable {
    /// `start` while a session is already active (running or paused).
    case sessionAlreadyActive
    /// `pause`/`resume`/`end` with no started session (also after `end()`
    /// closed the lifecycle).
    case noActiveSession
    /// `pause` while already paused.
    case alreadyPaused
    /// `resume` while running — the session was never paused.
    case resumeWhileRunning
}

// MARK: - Result

/// The timing/telemetry part of the §13 session log (issue #12) — exactly the
/// fields the engine owns. `task_completed`, `notes` and the focus/energy
/// ratings are deliberately NOT here: the end-of-session flow (#22) composes
/// the final `FocusSessionLog` (the #11 type) from this result plus the
/// modal's answers, and appends it via `DailyLogStore`.
///
/// Duration fields are whole minutes with the pinned rounding rule documented
/// on `FocusSessionEngine` (nearest minute, half away from zero, from
/// second-precision monotonic interval sums).
public struct FocusSessionResult: Equatable, Sendable {
    /// Assigned at `start` (PRD §18: reference by ID).
    public let sessionID: UUID
    /// The one task/subtask the session links to (PRD §9.1).
    public let taskID: UUID
    /// Wall clock at `start` — timestamps only, never duration math.
    public let startedAt: Date
    /// Wall clock at `end`.
    public let endedAt: Date
    /// Whole minutes of actual focus; paused intervals excluded (PRD §9.3).
    public let focusedDuration: Int
    /// Number of `pause()` transitions in the session (PRD §9.4). A pause
    /// still open at `end()` counts.
    public let pauseCount: Int
    /// Whole minutes spent paused.
    public let pausedDuration: Int

    public init(
        sessionID: UUID,
        taskID: UUID,
        startedAt: Date,
        endedAt: Date,
        focusedDuration: Int,
        pauseCount: Int,
        pausedDuration: Int
    ) {
        self.sessionID = sessionID
        self.taskID = taskID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusedDuration = focusedDuration
        self.pauseCount = pauseCount
        self.pausedDuration = pausedDuration
    }
}

// MARK: - Engine

/// The pause-aware focus-session engine (issue #12, PRD §9.1–§9.4): a
/// UI-independent, deterministic state machine owning exactly one session
/// lifecycle at a time — `start` / `pause` / `resume` / `end`, pause
/// telemetry, and the pure derived display values (remaining time, progress)
/// the timer views (#20/#21) render. Its `end()` result feeds the
/// end-of-session flow (#22), which composes the final `FocusSessionLog`.
///
/// **Location decision (documented, #9 precedent):** `Domain/`, alongside
/// `StatusTransition`. This is a cross-cutting domain concern — consumed by
/// the timer UIs (#20/#21), the end-of-session flow (#22) and tests, with no
/// persistence knowledge of its own. It is neither a `Models/` value type nor
/// store-side persistence semantics (`Vault/`), so `Domain/` is the honest
/// home. Foundation only; no SwiftUI/AppKit imports.
///
/// **Shape decision (engineer's choice, documented):** a struct with an
/// explicit state machine, not an actor. Value semantics keep every
/// transition deterministic and trivially testable (no isolation hopping in
/// tests), the UI holds one instance in `@State`, and the derived values are
/// pure functions of (state, now) callable from any view — there is no shared
/// mutable state to protect; concurrency isolation belongs to the caller.
/// After `end()` the engine returns to idle and is reusable for a fresh
/// session (new `session_id`, fresh telemetry); the completed result is
/// returned by `end()` and nothing retained.
///
/// **Clock injection (pinned):** all time comes from the injected
/// `FocusSessionClock` — no `Date()`/`DispatchTime.now()` calls inside the
/// engine, so every behavior is deterministic and testable. Monotonic
/// readings drive ALL duration math; wall-clock `Date` values are used only
/// for the `started_at`/`ended_at` timestamps.
///
/// **Interval summation & clock-change safety (pinned):** focused/paused
/// durations are computed by summing closed run/pause intervals measured with
/// the injected monotonic clock — never by wall-clock subtraction. A
/// suspend/resume-style gap that occurs **while paused** lands in the pause
/// segment and is excluded from focused time (tested). The honest v1 behavior
/// for an **unpaused** system-sleep gap: it counts as focused time. PRD §9.3
/// excludes only *paused* time; `ContinuousClock` (the production monotonic
/// source) keeps ticking through sleep, so the gap flows into the open run
/// segment. `ended_at − started_at` stays the timestamp authority and
/// `focused_duration` comes from run-interval summation — after an unpaused
/// sleep the two can legitimately disagree, and #22 composes the final log
/// with that understanding.
///
/// **Whole-minute rounding (pinned + tested):** the §13 duration fields
/// (`focusedDuration`, `pausedDuration`) are whole minutes, rounded to the
/// **nearest** minute (half away from zero) from second-precision interval
/// sums. Rationale: floor would systematically under-count — up to 59 s per
/// field per session, biasing daily totals low — while nearest-rounding
/// halves the worst-case error and is unbiased across sessions. Consequence
/// for the #11 append invariant (`ended_at − started_at ==
/// focused_duration + paused_duration`): it holds **exactly** whenever the
/// elapsed span is a whole number of minutes (every tested contract,
/// including the pinned 10/5/15 example). For arbitrary sub-minute end times,
/// independently rounding the two fields can drift their sum from the raw
/// second span by up to one minute; reconciling that at append time is #22's
/// composition job — the engine reports honest whole-minute fields.
///
/// **Duration expiry (engineer's choice, documented):** expiry is reported as
/// pure state — `remainingSeconds(at:)` clamps at 0, `progressFraction(at:)`
/// clamps at 1, and `isExpired(at:)` flips true at the boundary. There is no
/// callback, no auto-end and no auto-stop of logging: the session stays
/// active until the user calls `end()`, and focused time keeps accumulating
/// real focused time past the configured duration (only the remaining-time
/// display clamps).
///
/// **Telemetry semantics (PRD §9.4):** `pauseCount` is the number of
/// `pause()` calls; `pausedDuration` sums every closed pause segment —
/// including one still open at `end()` (ending from paused is allowed).
/// Individual pause intervals are not reported: the UI needs aggregates only.
///
/// **Persistence integration (issue #13 — the only extension this issue
/// makes):** `captureSnapshot()` / `restore(from:)` at the bottom of this
/// file round-trip the live state through an `ActiveSessionSnapshot` for
/// app-local persistence (#13; never the vault). Capture is a pure read +
/// arithmetic checkpoint; restore re-anchors the open segment into the new
/// process epoch. #12's state machine, summation, rounding and derived
/// values are untouched.
public struct FocusSessionEngine: Sendable {

    /// Pinned default session duration (PRD §9.2): 25 minutes, configurable
    /// per session via `start(taskID:duration:)` (no fixed preset buttons).
    public static let defaultDurationSeconds: TimeInterval = 25 * 60

    /// The injected clock, exposed so callers can feed its monotonic reading
    /// back into the pure derived functions (`remainingSeconds(at:)`, …) —
    /// one time authority for the whole session.
    public let clock: any FocusSessionClock

    /// The active session, or nil when idle (before `start` / after `end`).
    private var state: ActiveSession?

    public init(clock: any FocusSessionClock = SystemFocusSessionClock()) {
        self.clock = clock
    }

    // MARK: Lifecycle

    /// Whether a session lifecycle is currently open (running or paused).
    public var isActive: Bool { state != nil }

    /// Starts one session linked to exactly one task/subtask UUID
    /// (PRD §9.1). `duration` is this session's configured length in seconds
    /// (default 25 minutes, PRD §9.2). A fresh `session_id` UUID is assigned
    /// here. Throws `.sessionAlreadyActive` if a lifecycle is already open.
    public mutating func start(
        taskID: UUID,
        duration: TimeInterval = FocusSessionEngine.defaultDurationSeconds
    ) throws {
        guard state == nil else { throw FocusSessionError.sessionAlreadyActive }
        state = ActiveSession(
            sessionID: UUID(),
            taskID: taskID,
            durationSeconds: duration,
            startedAtWallClock: clock.wallClockNow,
            segmentStart: clock.monotonicSeconds
        )
    }

    /// Pauses the session: the open run segment closes into the focused
    /// accumulator and a pause segment opens (its time is excluded from
    /// focused accumulation, PRD §9.3). Pausing does not end the session.
    /// Throws `.noActiveSession` / `.alreadyPaused`.
    public mutating func pause() throws {
        guard var active = state else { throw FocusSessionError.noActiveSession }
        guard active.phase == .running else { throw FocusSessionError.alreadyPaused }
        let now = clock.monotonicSeconds
        active.accumulatedFocusedSeconds += max(0, now - active.segmentStart)
        active.pauseCount += 1
        active.phase = .paused
        active.segmentStart = now
        state = active
    }

    /// Resumes from a pause: the open pause segment closes into the paused
    /// accumulator and a run segment opens. Multiple pause/resume cycles per
    /// session are supported. Throws `.noActiveSession` /
    /// `.resumeWhileRunning`.
    public mutating func resume() throws {
        guard var active = state else { throw FocusSessionError.noActiveSession }
        guard active.phase == .paused else { throw FocusSessionError.resumeWhileRunning }
        let now = clock.monotonicSeconds
        active.accumulatedPausedSeconds += max(0, now - active.segmentStart)
        active.phase = .running
        active.segmentStart = now
        state = active
    }

    /// Ends the session and returns the timing/telemetry part of the §13 log
    /// (`FocusSessionResult`). Closing from either phase lands the open
    /// segment in the right accumulator. The engine returns to idle and is
    /// reusable. Throws `.noActiveSession`.
    @discardableResult
    public mutating func end() throws -> FocusSessionResult {
        guard var active = state else { throw FocusSessionError.noActiveSession }
        let now = clock.monotonicSeconds
        switch active.phase {
        case .running:
            active.accumulatedFocusedSeconds += max(0, now - active.segmentStart)
        case .paused:
            active.accumulatedPausedSeconds += max(0, now - active.segmentStart)
        }
        state = nil
        return FocusSessionResult(
            sessionID: active.sessionID,
            taskID: active.taskID,
            startedAt: active.startedAtWallClock,
            endedAt: clock.wallClockNow,
            focusedDuration: Self.minutes(fromSeconds: active.accumulatedFocusedSeconds),
            pauseCount: active.pauseCount,
            pausedDuration: Self.minutes(fromSeconds: active.accumulatedPausedSeconds)
        )
    }

    // MARK: Derived values (pure functions of state + now)

    /// Total focused seconds at monotonic reading `now`: closed run segments
    /// plus the currently open one. Paused intervals never contribute (PRD
    /// §9.3). Pure (no mutation); idle → 0. Keeps growing past the configured
    /// duration after expiry (documented expiry decision).
    public func focusedSeconds(at now: TimeInterval) -> TimeInterval {
        guard let active = state else { return 0 }
        var total = active.accumulatedFocusedSeconds
        if active.phase == .running {
            total += max(0, now - active.segmentStart)
        }
        return total
    }

    /// Whole seconds of configured time still left at `now`, floored to the
    /// second (a countdown never overstates) and clamped at 0 after expiry —
    /// the session itself stays active (pinned expiry decision). Idle → nil:
    /// "no session" is distinct from "expired", which is 0. Freezes while
    /// paused, because paused time contributes nothing to focused elapsed.
    public func remainingSeconds(at now: TimeInterval) -> Int? {
        guard let active = state else { return nil }
        let remaining = active.durationSeconds - focusedSeconds(at: now)
        guard remaining > 0 else { return 0 }
        return Int(remaining)
    }

    /// Focused progress toward the configured duration at `now`, clamped to
    /// 0…1 (1 == expired). Pure; idle → 0.
    public func progressFraction(at now: TimeInterval) -> Double {
        guard let active = state else { return 0 }
        guard active.durationSeconds > 0 else { return 1 }
        return min(1, max(0, focusedSeconds(at: now) / active.durationSeconds))
    }

    /// Pure expiry report: true once focused time has reached the configured
    /// duration. No auto-end, no side effects (documented expiry decision).
    public func isExpired(at now: TimeInterval) -> Bool {
        guard let active = state else { return false }
        return focusedSeconds(at: now) >= active.durationSeconds
    }

    // MARK: Internals

    /// Pinned whole-minute rounding: nearest minute, half away from zero,
    /// from the second-precision monotonic sum (documented in the header).
    private static func minutes(fromSeconds seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded(.toNearestOrAwayFromZero))
    }

    /// Explicit state machine for one session lifecycle. Interval summation:
    /// `segmentStart` is the monotonic reading at which the current phase
    /// opened; every transition closes it into the matching accumulator, so a
    /// paused interval can never leak into focused time and no wall-clock
    /// subtraction is ever involved.
    private struct ActiveSession: Sendable {
        let sessionID: UUID
        let taskID: UUID
        let durationSeconds: TimeInterval
        let startedAtWallClock: Date

        var accumulatedFocusedSeconds: TimeInterval = 0
        var accumulatedPausedSeconds: TimeInterval = 0
        var pauseCount = 0
        var phase: Phase = .running
        var segmentStart: TimeInterval

        enum Phase: Sendable {
            case running
            case paused
        }
    }
}

// MARK: - Persistence integration (issue #13)

/// The #13 snapshot round-trip. This extension is the ONLY engine change
/// issue #13 makes: #12's lifecycle transitions, interval summation,
/// rounding and derived values are untouched. Both operations live here
/// because the `ActiveSession` state is private to this file — capture is
/// deliberately a **pure read + arithmetic checkpoint** (a non-mutating
/// `func`, so it cannot touch live state, exactly as criterion 1 pins), and
/// restore is the exact rehydration its math defines.
public extension FocusSessionEngine {

    /// Captures the live session as an `ActiveSessionSnapshot` exactly as of
    /// the save instant; `nil` when idle (nothing to persist).
    ///
    /// Pinned checkpoint math (issue #13, criterion 1): the open segment is
    /// checkpointed into its accumulator by pure arithmetic —
    /// `accumulated += max(0, now − segmentStart)` for the current phase —
    /// and the anchor (`segmentStartMonotonic`) is the save-instant reading.
    /// The live engine state is NOT mutated: its open segment stays open with
    /// its original `segmentStart`, so ongoing summation is unaffected.
    ///
    /// Consequence (pinned honest loss statement): everything accumulated
    /// after this capture and before the close/crash lives only in memory —
    /// bounded loss ≤ 1 autosave interval (cadence contract on
    /// `ActiveSessionCoordinator`); recovery from this save point is exact.
    func captureSnapshot() -> ActiveSessionSnapshot? {
        guard let active = state else { return nil }
        let now = clock.monotonicSeconds
        var focused = active.accumulatedFocusedSeconds
        var paused = active.accumulatedPausedSeconds
        switch active.phase {
        case .running:
            focused += max(0, now - active.segmentStart)
        case .paused:
            paused += max(0, now - active.segmentStart)
        }
        return ActiveSessionSnapshot(
            sessionID: active.sessionID,
            taskID: active.taskID,
            duration: active.durationSeconds,
            startedAt: active.startedAtWallClock,
            accumulatedFocusedSeconds: focused,
            accumulatedPausedSeconds: paused,
            pauseCount: active.pauseCount,
            isPaused: active.phase == .paused,
            segmentStartMonotonic: now)
    }

    /// Rehydrates the engine from a snapshot so run-interval summation
    /// continues seamlessly in the NEW process epoch (issue #13, criterion 1
    /// + 5). Accumulators, phase, pause count and the IDs are copied
    /// verbatim; `started_at` is carried verbatim so the eventual §13 log
    /// stays correct.
    ///
    /// Pinned re-anchor math: the stored monotonic reading is meaningless
    /// across a restart (each process's `SystemFocusSessionClock` anchors at
    /// init), so `segmentStart = clock.monotonicSeconds` — the new epoch's
    /// reading at the restore instant. From then on #12's summation is
    /// untouched and uninterrupted:
    /// `focusedSeconds(at:) = accumulated_focused_seconds +
    /// max(0, now − segmentStart)` while running — identical to the original
    /// run. The snapshot's stored anchor is never read (diagnostic only).
    ///
    /// Throws `.sessionAlreadyActive` when a lifecycle is already open:
    /// restore is a launch-time recovery on an idle engine, and silently
    /// overwriting a live session would be data loss (PRD §18).
    mutating func restore(from snapshot: ActiveSessionSnapshot) throws {
        guard state == nil else { throw FocusSessionError.sessionAlreadyActive }
        var active = ActiveSession(
            sessionID: snapshot.sessionID,
            taskID: snapshot.taskID,
            durationSeconds: snapshot.duration,
            startedAtWallClock: snapshot.startedAt,
            segmentStart: clock.monotonicSeconds)  // re-anchor: NEW epoch
        active.accumulatedFocusedSeconds = snapshot.accumulatedFocusedSeconds
        active.accumulatedPausedSeconds = snapshot.accumulatedPausedSeconds
        active.pauseCount = snapshot.pauseCount
        active.phase = snapshot.isPaused ? .paused : .running
        state = active
    }
}
