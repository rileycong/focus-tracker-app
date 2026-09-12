import Foundation

/// The persisted image of one in-flight focus session (issue #13, PRD §22
/// criterion 21): everything needed to restore a `FocusSessionEngine`
/// mid-session in a **new process**. Stored as one JSON file in app-local
/// storage (Application Support) — never the vault (#13 pinned scope: the
/// vault holds only `Tasks/` and `Logs/YYYY-MM-DD.md`).
///
/// # Restoration math (pinned by issue #13, criterion 1)
///
/// The engine's monotonic epoch is per-process (`SystemFocusSessionClock`
/// anchors at init), so a stored monotonic reading is meaningless across a
/// restart. The snapshot therefore captures engine state **exactly as of the
/// save instant**: at capture, the open segment is checkpointed into its
/// accumulator (pure read + arithmetic, no live-state mutation required:
/// `accumulated += max(0, now − segmentStart)` for the current phase; anchor
/// = the save-instant reading). `restore` then re-anchors:
/// `segmentStart = clock.monotonicSeconds` in the **new** epoch and copies
/// accumulators/phase/IDs verbatim. From the restore instant, #12's summation
/// continues seamlessly: `focusedSeconds(at:) =
/// accumulated_focused_seconds + max(0, now − segmentStart)` while running —
/// identical to the original run. The stored `segmentStartMonotonic` anchor is
/// diagnostic content (it records the save-instant reading, i.e. where the
/// checkpointed segment's successor begins); restore never reads it, because
/// it re-anchors from the new clock. Wall-clock `started_at` is carried
/// verbatim so the eventual §13 log stays correct.
///
/// # Honest loss statement (pinned by issue #13, criterion 1 + 3)
///
/// In-memory-only time after the last save and before the close/crash is
/// unrecoverable — bounded loss **≤ 1 autosave interval** (the cadence
/// contract on `ActiveSessionCoordinator`); recovery from the last save point
/// is exact.
public struct ActiveSessionSnapshot: Codable, Equatable, Sendable {

    /// The session's identity (PRD §18: reference by ID).
    public var sessionID: UUID

    /// The one task/subtask the session links to (PRD §9.1).
    public var taskID: UUID

    /// The configured session length, seconds (PRD §9.2).
    public var duration: TimeInterval

    /// Wall-clock `Date` at `start` — timestamps only, never duration math.
    /// Carried verbatim across restarts.
    public var startedAt: Date

    /// Focused seconds from all closed run segments **plus** the open one,
    /// checkpointed at capture (second precision).
    public var accumulatedFocusedSeconds: TimeInterval

    /// Paused seconds from all closed pause segments **plus** the open one,
    /// checkpointed at capture (second precision).
    public var accumulatedPausedSeconds: TimeInterval

    /// Number of `pause()` transitions so far (PRD §9.4).
    public var pauseCount: Int

    /// Phase at the save instant: `true` = the open segment is a pause
    /// segment, `false` = a run segment.
    public var isPaused: Bool

    /// Monotonic anchor for the current interval: the save-instant reading
    /// (see the restoration math above). Per-process epoch — never reused as
    /// a duration across restarts; `restore` re-anchors from the new clock.
    public var segmentStartMonotonic: TimeInterval

    public init(
        sessionID: UUID,
        taskID: UUID,
        duration: TimeInterval,
        startedAt: Date,
        accumulatedFocusedSeconds: TimeInterval,
        accumulatedPausedSeconds: TimeInterval,
        pauseCount: Int,
        isPaused: Bool,
        segmentStartMonotonic: TimeInterval
    ) {
        self.sessionID = sessionID
        self.taskID = taskID
        self.duration = duration
        self.startedAt = startedAt
        self.accumulatedFocusedSeconds = accumulatedFocusedSeconds
        self.accumulatedPausedSeconds = accumulatedPausedSeconds
        self.pauseCount = pauseCount
        self.isPaused = isPaused
        self.segmentStartMonotonic = segmentStartMonotonic
    }

    /// JSON keys are the pinned snake_case names from issue #13.
    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case taskID = "task_id"
        case duration
        case startedAt = "started_at"
        case accumulatedFocusedSeconds = "accumulated_focused_seconds"
        case accumulatedPausedSeconds = "accumulated_paused_seconds"
        case pauseCount = "pause_count"
        case isPaused = "is_paused"
        case segmentStartMonotonic = "segment_start_monotonic"
    }
}
