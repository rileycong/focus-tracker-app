import Foundation

/// One logged break in a daily log file (`Logs/YYYY-MM-DD.md`, PRD §14.4 —
/// issue #11).
///
/// **Location decision (documented):** `Models/`, same reasoning as
/// `FocusSessionLog` — a domain value type consumed by the timer/break flows
/// (#12, #20, #22), with all file-format knowledge in `Vault/DailyLogCodec`.
///
/// §14.4 semantics: `duration` is the actual timed duration (whole minutes)
/// and is the field of record — breaks track no overrun, no ratings.
/// `breakID`/`ended_at` are carried because the fixture schema includes them:
/// an entry stored with them must not lose them on re-serialize.
///
/// The append-time arithmetic check is
/// `ended_at − started_at == duration` (enforced by `DailyLogStore`).
public struct BreakLog: Codable, Hashable, Sendable {
    /// Stable identity of the logged break (PRD §18: reference by ID).
    public let breakID: UUID
    public let startedAt: Date
    public let endedAt: Date
    /// Whole minutes; the field of record (PRD §14.4).
    public let duration: Int

    public init(
        breakID: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        duration: Int
    ) {
        self.breakID = breakID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case breakID = "break_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case duration
    }
}
