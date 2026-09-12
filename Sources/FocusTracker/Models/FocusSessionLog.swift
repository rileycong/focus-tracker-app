import Foundation

/// One logged focus session in a daily log file (`Logs/YYYY-MM-DD.md`,
/// PRD §5.5, §13 — issue #11).
///
/// **Location decision (documented):** this type lives in `Models/` because it
/// is a domain value type — the timer (#12), the end-of-session flow (#22) and
/// the timer view's "Session N today" (#20) all construct and consume it, and
/// it carries no persistence knowledge of its own. The daily-log file format
/// (key order, YAML shape, byte stability) lives entirely in
/// `Vault/DailyLogCodec`, which maps this model to/from the fixture schema.
///
/// Field semantics per PRD §13:
/// - `focusedDuration` excludes paused time — the **caller** computes it; the
///   codec only checks arithmetic consistency on append
///   (`ended_at − started_at == focused_duration + paused_duration`).
/// - `focusRating`/`energyRating` have the domain 1–5; like the duration
///   invariant, the range is the caller's contract — the codec validates only
///   what the issue pins (missing/invalid required fields, append arithmetic).
/// - `notes` is the only optional field; every other field is required when
///   reading a day-file entry.
///
/// The YAML keys are the fixture's snake_case names (`session_id`, …); the
/// mapping is exercised by `DailyLogCodec`, which parses/serializes entries
/// directly against the file schema (this conformance exists so the type is
/// a first-class `Codable` model like the other `Models/` types).
public struct FocusSessionLog: Codable, Hashable, Sendable {
    /// Stable identity of the logged session (PRD §18: reference by ID).
    public let sessionID: UUID
    /// The task the session belongs to — rename-safe by ID, never by title
    /// (PRD §5.5).
    public let taskID: UUID
    public let startedAt: Date
    public let endedAt: Date
    /// Whole minutes of actual focus, excluding paused time (PRD §13).
    public let focusedDuration: Int
    public let pauseCount: Int
    /// Whole minutes spent paused; `≥ 0` is the caller's job (issue #11).
    public let pausedDuration: Int
    /// Domain 1–5 (PRD §13); not range-validated by the codec (documented).
    public let focusRating: Int
    /// Domain 1–5 (PRD §13); not range-validated by the codec (documented).
    public let energyRating: Int
    public let taskCompleted: Bool
    /// Optional free-form note; omitted in the file when nil.
    public let notes: String?

    public init(
        sessionID: UUID = UUID(),
        taskID: UUID,
        startedAt: Date,
        endedAt: Date,
        focusedDuration: Int,
        pauseCount: Int,
        pausedDuration: Int,
        focusRating: Int,
        energyRating: Int,
        taskCompleted: Bool,
        notes: String? = nil
    ) {
        self.sessionID = sessionID
        self.taskID = taskID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusedDuration = focusedDuration
        self.pauseCount = pauseCount
        self.pausedDuration = pausedDuration
        self.focusRating = focusRating
        self.energyRating = energyRating
        self.taskCompleted = taskCompleted
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case taskID = "task_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case focusedDuration = "focused_duration"
        case pauseCount = "pause_count"
        case pausedDuration = "paused_duration"
        case focusRating = "focus_rating"
        case energyRating = "energy_rating"
        case taskCompleted = "task_completed"
        case notes
    }
}
