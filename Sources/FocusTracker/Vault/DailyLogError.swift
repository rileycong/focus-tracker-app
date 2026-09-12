import Foundation

/// Errors surfaced by the daily-log codec and store (issue #11, PRD §5.5, §18).
///
/// **Reading is strict (documented choice (a) of issue #11):** a missing file
/// reads as an empty day, but every other problem — a file that cannot be
/// split or parsed, an entry missing/unparseable a required field — fails the
/// read with one of these typed errors instead of warning-skipping. (The #6
/// `VaultStore` warning-skip pattern fits a whole-vault scan, where one bad
/// file must not hide the rest; a day read has exactly one file, so there is
/// nothing left to return that would not be a silently wrong "empty day".)
/// Per-entry errors name the field and the offending entry (its index in the
/// list plus its `session_id`/`break_id` when the entry carried one — IDs are
/// decoded first for exactly that reason).
///
/// **Reading never enforces the arithmetic invariant** (documented): a
/// hand-edited file with inconsistent durations loads fine; the invariant is
/// enforced only on append (`sessionArithmeticMismatch` /
/// `breakArithmeticMismatch`), where a failure writes nothing.
///
/// All cases are `Equatable` (mirroring `FrontmatterError` and
/// `AtomicFileWriterError` conventions) so tests can assert exact cases, and
/// `Sendable` so errors can cross concurrency domains.
public enum DailyLogError: Error, Equatable, Sendable, CustomStringConvertible {
    // MARK: Reading — whole-file

    /// The day file exists but is not valid UTF-8, so it cannot be parsed.
    case nonUTF8Encoded(String)
    /// The day file's frontmatter could not be split (missing `---`
    /// delimiters) or its YAML block is not syntactically valid; the
    /// underlying `FrontmatterError` from the reused #4 splitter/decoder
    /// conventions is preserved.
    case malformedFrontmatter(FrontmatterError)
    /// The frontmatter carries top-level keys outside the day schema
    /// (`sessions`, `breaks`). Sorted for determinism. Fail-loud instead of
    /// silently dropping unknown data (PRD §18), same stance as #4.
    case unknownKeys([String])
    /// A top-level `sessions`/`breaks` key is present but is not a YAML list
    /// (`field` names the key).
    case wrongListType(field: String, value: String, expected: String)
    /// The day path exists but is a directory — nothing log-like can be read
    /// there.
    case dayPathIsADirectory(String)
    /// The day file exists but could not be read as bytes (e.g. permission
    /// denied); `reason` is the underlying error's description.
    case unreadableFile(fileName: String, reason: String)
    /// `Logs/` (or a parent directory) could not be created for the first
    /// log of a fresh vault; `reason` is the underlying error's description.
    case directoryCreationFailed(path: String, reason: String)

    // MARK: Reading — per-entry (names the field + the offending entry)

    /// An entry is missing a required field (or the field is an explicit
    /// null). Required = every field except `notes`.
    case missingField(entry: DailyLogEntryRef, field: String)
    /// An entry's field has the wrong YAML type (e.g. a quoted number where a
    /// plain integer is required, mirroring #4's strictness — no silent
    /// coercion).
    case wrongType(entry: DailyLogEntryRef, field: String, value: String, expected: String)
    /// An entry's ID field (`session_id`/`task_id`/`break_id`) is not a valid
    /// UUID.
    case invalidUUID(entry: DailyLogEntryRef, field: String, value: String)
    /// An entry's timestamp field (`started_at`/`ended_at`) is not exactly the
    /// offset-less second-precision convention (`2026-09-04T10:00:00`).
    case invalidTimestamp(entry: DailyLogEntryRef, field: String, value: String)
    /// An entry carries keys outside its schema. Fail-loud, same stance as
    /// top-level unknown keys (PRD §18).
    case unknownEntryKeys(entry: DailyLogEntryRef, keys: [String])
    /// A list element is not a mapping (`- 42`, `- just a string`).
    case entryNotAMapping(entry: DailyLogEntryRef)

    // MARK: Appending — arithmetic validation (enforced on append only)

    /// `appendSession` refused: `ended_at − started_at` (`spanSeconds`) does
    /// not equal `focused_duration + paused_duration` minutes. Nothing was
    /// written. (Subsumes `focused_duration ≤ ended − started` since
    /// `paused_duration ≥ 0` is the caller's contract.)
    case sessionArithmeticMismatch(
        sessionID: UUID, startedAt: String, endedAt: String,
        focusedMinutes: Int, pausedMinutes: Int, spanSeconds: Int)
    /// `appendBreak` refused: `ended_at − started_at` (`spanSeconds`) does not
    /// equal `duration` minutes. Nothing was written.
    case breakArithmeticMismatch(
        breakID: UUID, startedAt: String, endedAt: String,
        durationMinutes: Int, spanSeconds: Int)

    // MARK: Writing

    /// An `AtomicFileWriter` operation failed; the underlying #5 typed error
    /// is preserved unchanged (vault/`Logs/` unavailable, permission denied,
    /// …) — never a crash, never a partial write.
    case writeFailed(AtomicFileWriterError)

    public var description: String {
        switch self {
        case .nonUTF8Encoded(let name):
            return "day file is not valid UTF-8, cannot parse: \(name)"
        case .malformedFrontmatter(let underlying):
            return "day file frontmatter is malformed: \(underlying)"
        case .unknownKeys(let keys):
            return "day file frontmatter has unknown top-level keys: \(keys.sorted().joined(separator: ", "))"
        case .wrongListType(let field, let value, let expected):
            return "day file field \(field) has value \"\(value)\", expected \(expected)"
        case .dayPathIsADirectory(let path):
            return "day log path is a directory, cannot read: \(path)"
        case .unreadableFile(let name, let reason):
            return "day file could not be read: \(name) — \(reason)"
        case .directoryCreationFailed(let path, let reason):
            return "could not create Logs/ directory: \(path) — \(reason)"
        case .missingField(let entry, let field):
            return "day log \(entry) is missing required field \"\(field)\""
        case .wrongType(let entry, let field, let value, let expected):
            return "day log \(entry) field \"\(field)\" has value \"\(value)\", expected \(expected)"
        case .invalidUUID(let entry, let field, let value):
            return "day log \(entry) field \"\(field)\" is not a valid UUID: \"\(value)\""
        case .invalidTimestamp(let entry, let field, let value):
            return
                "day log \(entry) field \"\(field)\" is not an offset-less second-precision timestamp: \"\(value)\""
        case .unknownEntryKeys(let entry, let keys):
            return "day log \(entry) has unknown keys: \(keys.sorted().joined(separator: ", "))"
        case .entryNotAMapping(let entry):
            return "day log \(entry) is not a mapping"
        case .sessionArithmeticMismatch(
            let sessionID, let startedAt, let endedAt, let focused, let paused, let span):
            return
                "session \(sessionID.uuidString) rejected: \(startedAt) → \(endedAt) spans \(span)s but focused_duration (\(focused) min) + paused_duration (\(paused) min) = \((focused + paused) * 60)s — nothing written"
        case .breakArithmeticMismatch(let breakID, let startedAt, let endedAt, let duration, let span):
            return
                "break \(breakID.uuidString) rejected: \(startedAt) → \(endedAt) spans \(span)s but duration is \(duration) min — nothing written"
        case .writeFailed(let underlying):
            return "atomic file operation failed: \(underlying)"
        }
    }
}

/// Identifies the offending entry of a per-entry read error: which list it
/// belongs to, its index in that list, and its `session_id`/`break_id` when
/// the entry carried one (IDs are decoded before the other fields so errors
/// can name the entry even when a later field is the problem).
public struct DailyLogEntryRef: Sendable, Equatable, CustomStringConvertible {
    public enum List: Sendable, Equatable {
        case sessions
        case breaks
    }

    public let list: List
    public let index: Int
    public let id: UUID?

    public init(list: List, index: Int, id: UUID?) {
        self.list = list
        self.index = index
        self.id = id
    }

    public var description: String {
        let listName: String
        switch list {
        case .sessions: listName = "sessions"
        case .breaks: listName = "breaks"
        }
        if let id {
            return "\(listName)[\(index)] (\(id.uuidString))"
        }
        return "\(listName)[\(index)]"
    }
}
