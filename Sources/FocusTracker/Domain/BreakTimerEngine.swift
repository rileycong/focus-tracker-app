import Foundation

// MARK: - Errors

/// Typed, `Equatable` transition errors (issue #23). One case per invalid
/// transition — never a silent no-op (house refusal contract, #9/#12
/// precedent).
public enum BreakTimerError: Error, Equatable, Sendable {
    /// `start` while a break is already running — breaks are single-lifecycle
    /// like sessions.
    case breakAlreadyActive
    /// `end` with no started break (also after `end()` closed the lifecycle).
    case noActiveBreak
}

// MARK: - Result

/// The timing part of the §14.4 break log (issue #23) — exactly the fields
/// the engine owns. The end-of-break flow composes the final `BreakLog` (the
/// #11 type) from this result and appends it via `DailyLogStore.appendBreak`
/// to the break's END day.
///
/// Duration is whole minutes with the pinned rounding rule documented on the
/// engine (nearest minute, half away from zero). `endedAt` is reconciled so
/// `endedAt − startedAt == duration` holds EXACTLY — the #11 append
/// invariant `DailyLogStore.appendBreak` validates before any I/O.
public struct BreakResult: Equatable, Sendable {
    /// Assigned at `start` (PRD §18: reference by ID) — carried into the
    /// composed `BreakLog.breakID` so the identity the engine assigned is
    /// the identity the file stores.
    public let breakID: UUID
    /// Wall clock at `start` — timestamps only, never duration math.
    public let startedAt: Date
    /// Wall-clock timestamp reconciled to `startedAt + duration` minutes
    /// (see the engine's pinned reconciliation decision).
    public let endedAt: Date
    /// Whole minutes of ACTUAL timed break (nearest-minute rounding);
    /// early end → the shorter actual duration, post-expiry end → clamped
    /// to the configured duration (§14.4: no overrun tracking).
    public let duration: Int

    public init(breakID: UUID, startedAt: Date, endedAt: Date, duration: Int) {
        self.breakID = breakID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
    }
}

// MARK: - Engine

/// The break countdown engine (issue #23, PRD §14.2): a deliberately simpler
/// sibling of `FocusSessionEngine` (#12) — one countdown lifecycle
/// (`start(duration:)` / pure derived values / `end()`), NO pause/resume
/// (§9.3 pause semantics are focus-session-only), no pause telemetry, no
/// task linkage (a break links to no task, PRD §14.2).
///
/// **Location decision (documented, #9/#12 precedent):** `Domain/`, alongside
/// `FocusSessionEngine` — a cross-cutting domain concern consumed by the
/// break view (#23), the `AppModel` break flow and tests, with no
/// persistence knowledge of its own. Neither a `Models/` value type nor
/// store-side semantics (`Vault/`). Foundation only; no SwiftUI/AppKit
/// imports.
///
/// **Shape decision (engineer's choice, documented — same as #12):** a struct
/// value type with an explicit state machine, not an actor. Value semantics
/// keep every transition deterministic and trivially testable, the UI holds
/// one instance (the `AppModel` keeps the live one), and the derived values
/// are pure functions of (state, now) callable from any view. After `end()`
/// the engine returns to idle and is reusable for a fresh break (new
/// `break_id`); the completed result is returned by `end()` and nothing
/// retained.
///
/// **Clock injection (pinned, #12 precedent):** all time comes from the
/// injected `FocusSessionClock` — reused AS-IS, no new clock protocol and no
/// `Date()`/`DispatchTime.now()` calls inside the engine. Monotonic readings
/// drive ALL duration math; wall-clock `Date` values are used only for the
/// `started_at`/`ended_at` timestamps.
///
/// **Whole-minute rounding (pinned, #12 rule):** `duration` is whole minutes,
/// rounded to the NEAREST minute (half away from zero) from the
/// second-precision monotonic elapsed. Nearest (not floor) so a short break
/// is not systematically under-counted, for the same reason #12 pins it.
///
/// **Timestamp reconciliation (pinned, issue #23 criterion 10):** `endedAt`
/// is reported so `endedAt − startedAt == duration` holds EXACTLY — the #11
/// append invariant `DailyLogStore.appendBreak` validates before any I/O
/// (a mismatch writes nothing and the break log, being transient and
/// in-memory, would be lost for good). The engine therefore reports
/// `endedAt = startedAt + duration minutes` in every case:
/// - an early end of a whole-minute elapsed reconciles to the real wall
///   instant exactly (monotonic and wall advanced together);
/// - a sub-minute early end reconciles `ended_at` to
///   `started_at + duration` (the issue's pinned example — e.g. a 29 s
///   break logs 0 minutes with `ended_at == started_at`);
/// - a post-expiry end reports the EXPIRY INSTANT
///   (`startedAt + configured seconds`): for the pinned default (300 s) and
///   every whole-minute configured duration this is exactly
///   `startedAt + duration minutes`, so the two pinned statements
///   ("ended_at = the expiry instant" and "ended − started == duration
///   exactly") coincide. For a hypothetical non-whole-minute configured
///   duration the #11 invariant wins (data integrity, PRD §18): the expiry
///   instant is reconciled to the whole-minute timestamp rather than
///   reporting a span the store would refuse.
///
/// **Duration expiry (pinned, mirrors #12):** expiry is reported as pure
/// state — `remainingSeconds(at:)` clamps at 0, `progressFraction(at:)`
/// clamps at 1, and `isExpired(at:)` flips true at the boundary. There is NO
/// callback, NO auto-end, NO auto-anything (§19 non-goals): the break screen
/// stays up until the user acts, and time past expiry is never counted,
/// displayed or logged (§14.4: the timer stops at expiry).
///
/// **NOT persisted (documented honest loss, #13 grooming note / PRD §14):**
/// no snapshot, no coordinator, no recovery. Breaks are transient — quitting
/// the app mid-break loses the break and logs nothing. `duration` is the
/// single field of record and it exists only after the user ends the break.
public struct BreakTimerEngine: Sendable {

    /// Pinned default break duration (PRD §14.2): 5 minutes. Configuration
    /// happens before start only (issue #23 criterion 5 — no mid-break
    /// reconfiguration).
    public static let defaultDurationSeconds: TimeInterval = 5 * 60

    /// The injected clock, exposed so callers can feed its monotonic reading
    /// back into the pure derived functions — one time authority for the
    /// whole break.
    public let clock: any FocusSessionClock

    /// The active break, or nil when idle (before `start` / after `end`).
    private var state: ActiveBreak?

    public init(clock: any FocusSessionClock = SystemFocusSessionClock()) {
        self.clock = clock
    }

    // MARK: Lifecycle

    /// Whether a break lifecycle is currently open.
    public var isActive: Bool { state != nil }

    /// The configured duration of the active break in seconds (nil when
    /// idle). Configuration is fixed at `start` — no mid-break changes.
    public var configuredDurationSeconds: TimeInterval? {
        state?.durationSeconds
    }

    /// Starts one break countdown of `duration` seconds (default 5 minutes,
    /// PRD §14.2). A fresh `break_id` UUID is assigned here. Throws
    /// `.breakAlreadyActive` if a lifecycle is already open.
    public mutating func start(
        duration: TimeInterval = BreakTimerEngine.defaultDurationSeconds
    ) throws {
        guard state == nil else { throw BreakTimerError.breakAlreadyActive }
        state = ActiveBreak(
            breakID: UUID(),
            durationSeconds: duration,
            startedAtWallClock: clock.wallClockNow,
            startMonotonic: clock.monotonicSeconds)
    }

    /// Ends the break and returns the timing part of the §14.4 log
    /// (`BreakResult`). The elapsed time is clamped at the configured
    /// duration BEFORE rounding (§14.4: no overrun — time past expiry is
    /// never counted), rounded to whole minutes, and `endedAt` is reconciled
    /// so `endedAt − startedAt == duration` holds exactly (pinned decision
    /// in the type documentation). The engine returns to idle and is
    /// reusable. Throws `.noActiveBreak`.
    @discardableResult
    public mutating func end() throws -> BreakResult {
        guard let active = state else { throw BreakTimerError.noActiveBreak }
        let now = clock.monotonicSeconds
        let elapsed = max(0, now - active.startMonotonic)
        let counted = min(elapsed, active.durationSeconds)
        let minutes = Self.minutes(fromSeconds: counted)
        state = nil
        let endedAt = active.startedAtWallClock.addingTimeInterval(
            TimeInterval(minutes) * 60)
        return BreakResult(
            breakID: active.breakID,
            startedAt: active.startedAtWallClock,
            endedAt: endedAt,
            duration: minutes)
    }

    // MARK: Derived values (pure functions of state + now)

    /// Total elapsed break seconds at monotonic reading `now`. Pure (no
    /// mutation); idle → 0. Grows past the configured duration after expiry,
    /// but every consumer clamps (see below, and `end()`).
    private func elapsedSeconds(at now: TimeInterval) -> TimeInterval {
        guard let active = state else { return 0 }
        return max(0, now - active.startMonotonic)
    }

    /// Whole seconds of configured time still left at `now`, floored to the
    /// second (a countdown never overstates) and clamped at 0 after expiry —
    /// the break itself stays active (pinned expiry decision). Idle → nil:
    /// "no break" is distinct from "expired", which is 0.
    public func remainingSeconds(at now: TimeInterval) -> Int? {
        guard let active = state else { return nil }
        let remaining = active.durationSeconds - elapsedSeconds(at: now)
        guard remaining > 0 else { return 0 }
        return Int(remaining)
    }

    /// Progress toward the configured duration at `now`, clamped to 0…1
    /// (1 == expired). Pure; idle → 0.
    public func progressFraction(at now: TimeInterval) -> Double {
        guard let active = state else { return 0 }
        guard active.durationSeconds > 0 else { return 1 }
        return min(1, max(0, elapsedSeconds(at: now) / active.durationSeconds))
    }

    /// Pure expiry report: true once elapsed time has reached the configured
    /// duration. No auto-end, no side effects (pinned expiry decision) — the
    /// break screen stays up until the user acts.
    public func isExpired(at now: TimeInterval) -> Bool {
        guard let active = state else { return false }
        return elapsedSeconds(at: now) >= active.durationSeconds
    }

    // MARK: Internals

    /// Pinned whole-minute rounding: nearest minute, half away from zero,
    /// from the second-precision monotonic elapsed (documented in the
    /// header; the #12 rule).
    private static func minutes(fromSeconds seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded(.toNearestOrAwayFromZero))
    }

    /// Explicit state machine for one break lifecycle. No pause phases, no
    /// accumulators — the single monotonic anchor plus the configured
    /// duration IS the state.
    private struct ActiveBreak: Sendable {
        let breakID: UUID
        let durationSeconds: TimeInterval
        let startedAtWallClock: Date
        let startMonotonic: TimeInterval
    }
}
