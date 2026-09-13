import Foundation
import Yams

/// The parsed content of one daily log file (issue #11): the typed entries in
/// file order plus the opaque Markdown body (everything after the closing
/// `---`, byte-for-byte).
///
/// **Body exposed (documented choice):** the issue leaves this to the
/// engineer. The body is exposed here because byte-preserving callers — the
/// `DailyLogStore` append path, and tests proving "existing entries + body
/// untouched byte-for-byte" — need the exact body text to re-attach it
/// unchanged (same rule as `VaultStore` bodies: opaque, never re-derived).
/// The store's read API (`readDay(for:)`) deliberately does *not* expose it.
public struct ParsedDailyLog: Sendable, Equatable {
    /// The day's sessions in file order.
    public var log: DailyLog
    /// The file's Markdown body after the closing `---`, byte-for-byte.
    public var body: String

    public init(log: DailyLog, body: String) {
        self.log = log
        self.body = body
    }
}

/// The day's sessions and breaks in file order — the typed content of
/// `Logs/YYYY-MM-DD.md` without the opaque body.
public struct DailyLog: Sendable, Equatable {
    public var sessions: [FocusSessionLog]
    public var breaks: [BreakLog]

    public init(sessions: [FocusSessionLog] = [], breaks: [BreakLog] = []) {
        self.sessions = sessions
        self.breaks = breaks
    }
}

/// Codec for the daily log format (issue #11, PRD §5.5, §13, §14.4, §18):
/// `---`-delimited YAML frontmatter with top-level `sessions:`/`breaks:` lists
/// of entries plus an opaque Markdown body. The format's single source of
/// truth is `fixtures/sample-vault/Logs/2026-09-04.md`; parsing it succeeds
/// with exact values and re-serializing the parsed content reproduces it
/// byte-for-byte.
///
/// The codec operates purely on text in memory; callers own file access and
/// concurrency (the `DailyLogStore` actor wraps this codec with the #5
/// `AtomicFileWriter`).
///
/// # Reading (documented decisions)
/// - **Missing keys read as empty lists**: a frontmatter without `sessions:`
///   and/or `breaks:` (including a completely empty frontmatter) yields empty
///   lists — never an error.
/// - **Tolerant in exactly one direction**: only a missing *file* is tolerated
///   (by the store, as an empty day). Everything else fails with a typed
///   `DailyLogError`: malformed frontmatter/YAML, unknown top-level or
///   per-entry keys (fail-loud instead of silently dropping data, PRD §18 —
///   same stance as the #4 task codec), an entry that is not a mapping, or a
///   required field that is missing/unparseable. Required = every field except
///   `notes`. Per-entry errors name the field and the offending entry (its
///   index plus its `session_id`/`break_id` — IDs are decoded first so errors
///   can carry them).
/// - **No arithmetic enforcement on read** (pinned): a hand-edited file whose
///   `ended_at − started_at` does not match the durations still loads. The
///   invariant is enforced only on append (see `appendValidationFailure`).
/// - Lenient about things that cannot lose data (any key order, quoted
///   scalars, `!!str`/timestamp-tagged scalars, CRLF), strict about
///   everything that could (no silent coercion of quoted numbers/bools).
///
/// # Serialization strategy (documented, engineer's choice)
/// **Hand-rolled writer** — the same approach as the #4 `FrontmatterEncoder`:
/// fixed key order (sessions before breaks; each entry's keys in fixture
/// order), plain scalars, two-space list indentation with `- ` markers,
/// `[]` for empty lists, both top-level keys always present. The only
/// free-form string (`notes`) goes through Yams' emitter via `scalar(_:)`
/// below — a deliberate local mirror of `FrontmatterEncoder`'s private helper
/// (existing #4 files must not be edited), so quoting semantics are identical.
/// Hand-rolled rather than dumping the model through Yams' emitter because the
/// fixture-exact layout (entry keys inline after `- `, exact indentation and
/// key order, `[]` for empty lists) cannot be produced by a generic emitter
/// configuration; with fixed code paths the output is deterministic and the
/// round trip parse → serialize is the identity.
///
/// - `notes` is omitted when nil (nothing is written as `null`).
/// - UUIDs are written lowercase (fixture style); reading accepts any case.
/// - Timestamps via `DailyLogDay.timestampString(from:)` — the single-place
///   offset-less ISO 8601 convention.
/// - The body is appended untouched after the closing `---`; the fixture-style
///   blank line between delimiter and body is the body's own leading `\n`.
public enum DailyLogCodec {}

// MARK: - Reading

extension DailyLogCodec {
    /// Parses a full day file (frontmatter + body) into its typed entries and
    /// the opaque body. Throws `DailyLogError` (see the type documentation);
    /// does NOT enforce the append-time arithmetic invariant.
    public static func parseDay(_ fileText: String) throws -> ParsedDailyLog {
        let (frontmatter, body): (String, String)
        do {
            (frontmatter, body) = try FrontmatterCodec.split(fileText)
        } catch let error as FrontmatterError {
            throw DailyLogError.malformedFrontmatter(error)
        }
        let log = try decodeDay(frontmatter: frontmatter)
        return ParsedDailyLog(log: log, body: body)
    }

    /// Decodes raw day-file frontmatter YAML into a `DailyLog`.
    public static func decodeDay(frontmatter: String) throws -> DailyLog {
        let node: Node?
        do {
            node = try Yams.compose(yaml: frontmatter)
        } catch {
            throw DailyLogError.malformedFrontmatter(
                .invalidYAML(String(describing: error)))
        }
        guard let node else {
            // Empty frontmatter: no keys → both lists empty (documented).
            return DailyLog()
        }
        guard case .mapping(let mapping) = node else {
            throw DailyLogError.wrongListType(
                field: "frontmatter", value: summary(of: node), expected: "mapping")
        }
        try checkUnknownKeys(in: mapping, allowed: ["sessions", "breaks"])
        return DailyLog(
            sessions: try sessions(in: mapping),
            breaks: try breaks(in: mapping))
    }

    // MARK: Schema

    private static let sessionKeys: Set<String> = [
        "session_id", "task_id", "started_at", "ended_at",
        "focused_duration", "pause_count", "paused_duration",
        "focus_rating", "energy_rating", "task_completed", "notes",
    ]

    private static let breakKeys: Set<String> = [
        "break_id", "started_at", "ended_at", "duration",
    ]

    // MARK: Lists

    private static func sessions(in mapping: Node.Mapping) throws -> [FocusSessionLog] {
        guard let node = value("sessions", in: mapping) else { return [] }
        guard case .sequence(let sequence) = node else {
            throw DailyLogError.wrongListType(
                field: "sessions", value: summary(of: node), expected: "list")
        }
        return try sequence.enumerated().map { index, node in
            try session(from: node, index: index)
        }
    }

    private static func breaks(in mapping: Node.Mapping) throws -> [BreakLog] {
        guard let node = value("breaks", in: mapping) else { return [] }
        guard case .sequence(let sequence) = node else {
            throw DailyLogError.wrongListType(
                field: "breaks", value: summary(of: node), expected: "list")
        }
        return try sequence.enumerated().map { index, node in
            try breakEntry(from: node, index: index)
        }
    }

    private static func session(from node: Node, index: Int) throws -> FocusSessionLog {
        let provisionalRef = DailyLogEntryRef(list: .sessions, index: index, id: nil)
        guard case .mapping(let mapping) = node else {
            throw DailyLogError.entryNotAMapping(entry: provisionalRef)
        }
        try checkUnknownKeys(in: mapping, allowed: sessionKeys, ref: provisionalRef)
        // The ID is decoded first so every later error can name the entry.
        let sessionID = try requiredUUID("session_id", in: mapping, ref: provisionalRef)
        let ref = DailyLogEntryRef(list: .sessions, index: index, id: sessionID)
        let taskID = try requiredUUID("task_id", in: mapping, ref: ref)
        let startedAt = try requiredTimestamp("started_at", in: mapping, ref: ref)
        let endedAt = try requiredTimestamp("ended_at", in: mapping, ref: ref)
        return FocusSessionLog(
            sessionID: sessionID,
            taskID: taskID,
            startedAt: startedAt,
            endedAt: endedAt,
            focusedDuration: try requiredInt("focused_duration", in: mapping, ref: ref),
            pauseCount: try requiredInt("pause_count", in: mapping, ref: ref),
            pausedDuration: try requiredInt("paused_duration", in: mapping, ref: ref),
            focusRating: try requiredInt("focus_rating", in: mapping, ref: ref),
            energyRating: try requiredInt("energy_rating", in: mapping, ref: ref),
            taskCompleted: try requiredBool("task_completed", in: mapping, ref: ref),
            notes: try optionalNotes("notes", in: mapping, ref: ref))
    }

    private static func breakEntry(from node: Node, index: Int) throws -> BreakLog {
        let provisionalRef = DailyLogEntryRef(list: .breaks, index: index, id: nil)
        guard case .mapping(let mapping) = node else {
            throw DailyLogError.entryNotAMapping(entry: provisionalRef)
        }
        try checkUnknownKeys(in: mapping, allowed: breakKeys, ref: provisionalRef)
        let breakID = try requiredUUID("break_id", in: mapping, ref: provisionalRef)
        let ref = DailyLogEntryRef(list: .breaks, index: index, id: breakID)
        let startedAt = try requiredTimestamp("started_at", in: mapping, ref: ref)
        let endedAt = try requiredTimestamp("ended_at", in: mapping, ref: ref)
        return BreakLog(
            breakID: breakID,
            startedAt: startedAt,
            endedAt: endedAt,
            duration: try requiredInt("duration", in: mapping, ref: ref))
    }

    // MARK: Field readers
    // Local mirrors of the #4 decoder's private helpers (existing files are
    // frozen): explicit null reads as absent; string scalars are str-tagged,
    // quoted, or (for timestamps) timestamp-tagged; ints/bools must be plain
    // correctly-tagged scalars — no silent coercion.

    /// The mapping's value for `field`, treating an explicit null (`key:`,
    /// `key: null`, `key: ~`) as absent.
    private static func value(_ field: String, in mapping: Node.Mapping) -> Node? {
        guard let node = mapping[Node(field)] else { return nil }
        if case .scalar(let scalar) = node,
            node.tag.rawValue == Tag.Name.null.rawValue, scalar.style == .plain {
            return nil
        }
        return node
    }

    private static func stringScalar(
        _ node: Node, allowingTimestampTag: Bool = false
    ) -> String? {
        guard case .scalar(let scalar) = node else { return nil }
        let tagName = node.tag.rawValue
        if tagName == Tag.Name.str.rawValue { return scalar.string }
        if allowingTimestampTag && tagName == Tag.Name.timestamp.rawValue { return scalar.string }
        if scalar.style != .plain { return scalar.string }
        return nil
    }

    private static func checkUnknownKeys(in mapping: Node.Mapping, allowed: Set<String>) throws {
        var unknown: [String] = []
        for (key, _) in mapping {
            switch key {
            case .scalar(let scalar): unknown.append(scalar.string)
            default: unknown.append(summary(of: key))
            }
        }
        let unexpected = unknown.filter { !allowed.contains($0) }.sorted()
        if !unexpected.isEmpty {
            throw DailyLogError.unknownKeys(unexpected)
        }
    }

    private static func checkUnknownKeys(
        in mapping: Node.Mapping, allowed: Set<String>, ref: DailyLogEntryRef
    ) throws {
        var unknown: [String] = []
        for (key, _) in mapping {
            switch key {
            case .scalar(let scalar): unknown.append(scalar.string)
            default: unknown.append(summary(of: key))
            }
        }
        let unexpected = unknown.filter { !allowed.contains($0) }.sorted()
        if !unexpected.isEmpty {
            throw DailyLogError.unknownEntryKeys(entry: ref, keys: unexpected)
        }
    }

    private static func requiredUUID(
        _ field: String, in mapping: Node.Mapping, ref: DailyLogEntryRef
    ) throws -> UUID {
        guard let node = value(field, in: mapping) else {
            throw DailyLogError.missingField(entry: ref, field: field)
        }
        guard let raw = stringScalar(node) else {
            throw DailyLogError.wrongType(
                entry: ref, field: field, value: summary(of: node), expected: "string")
        }
        guard let uuid = UUID(uuidString: raw) else {
            throw DailyLogError.invalidUUID(entry: ref, field: field, value: raw)
        }
        return uuid
    }

    private static func requiredTimestamp(
        _ field: String, in mapping: Node.Mapping, ref: DailyLogEntryRef
    ) throws -> Date {
        guard let node = value(field, in: mapping) else {
            throw DailyLogError.missingField(entry: ref, field: field)
        }
        guard let raw = stringScalar(node, allowingTimestampTag: true) else {
            throw DailyLogError.wrongType(
                entry: ref, field: field, value: summary(of: node),
                expected: "offset-less timestamp string")
        }
        guard let date = DailyLogDay.date(fromTimestamp: raw) else {
            throw DailyLogError.invalidTimestamp(entry: ref, field: field, value: raw)
        }
        return date
    }

    private static func requiredInt(
        _ field: String, in mapping: Node.Mapping, ref: DailyLogEntryRef
    ) throws -> Int {
        guard let node = value(field, in: mapping) else {
            throw DailyLogError.missingField(entry: ref, field: field)
        }
        guard
            case .scalar(let scalar) = node,
            scalar.style == .plain,
            node.tag.rawValue == Tag.Name.int.rawValue,
            let parsed = Int(scalar.string)
        else {
            throw DailyLogError.wrongType(
                entry: ref, field: field, value: summary(of: node), expected: "integer")
        }
        return parsed
    }

    private static func requiredBool(
        _ field: String, in mapping: Node.Mapping, ref: DailyLogEntryRef
    ) throws -> Bool {
        guard let node = value(field, in: mapping) else {
            throw DailyLogError.missingField(entry: ref, field: field)
        }
        guard
            case .scalar(let scalar) = node,
            scalar.style == .plain,
            node.tag.rawValue == Tag.Name.bool.rawValue,
            let parsed = Bool(scalar.string)
        else {
            throw DailyLogError.wrongType(
                entry: ref, field: field, value: summary(of: node), expected: "true/false")
        }
        return parsed
    }

    private static func optionalNotes(
        _ field: String, in mapping: Node.Mapping, ref: DailyLogEntryRef
    ) throws -> String? {
        guard let node = value(field, in: mapping) else { return nil }
        guard let raw = stringScalar(node) else {
            throw DailyLogError.wrongType(
                entry: ref, field: field, value: summary(of: node), expected: "string")
        }
        return raw
    }

    /// Deterministic single-line description of a node for error payloads
    /// (same shape as the #4 decoder's private helper).
    private static func summary(of node: Node) -> String {
        switch node {
        case .scalar(let scalar): return scalar.string
        case .sequence(let sequence): return "[\(sequence.count) items]"
        case .mapping: return "{mapping}"
        case .alias: return "*alias"
        }
    }
}

// MARK: - Appending arithmetic validation (enforced on append only)

extension DailyLogCodec {
    /// The append-time arithmetic check for a session (pinned decision, as
    /// amended by issue #27): `ended_at − started_at` must equal
    /// `focused_duration + paused_duration` at the duration fields'
    /// whole-minute granularity — `nearest(exactSpanSeconds / 60) ==
    /// focused_duration + paused_duration`, nearest = half away from zero
    /// (the #12 engine's own rounding rule).
    ///
    /// # Issue #27's deliberate divergence from #11's original exact-second
    /// wording (documented)
    /// The duration fields are whole minutes, so the check is meaningful
    /// only at that granularity: the original
    /// `spanSeconds == (focused + paused) * 60` form could only ever pass
    /// for whole-minute-aligned spans — for any other span NO whole-minute
    /// log satisfies it (66 ≠ 60·k for any k, reconciled or not), which is
    /// the trap's root cause. Accepted consequence: spans within ±30 s of
    /// the minute sum pass (documented tolerance). The check still catches
    /// real corruption — a minute sum off by ≥ 1 minute from the span (a
    /// 3600 s span vs a 61-minute sum) still fails. The FILE FORMAT is
    /// untouched: fixtures byte-identical, parse behavior unchanged, and
    /// reading never enforces this check (hand-edited files still load).
    /// Non-finite spans (`exactSpanSeconds` → 0) and negative spans still
    /// fail against any non-negative minute sum, unchanged.
    ///
    /// Timestamps are second-precision; `exactSpanSeconds` itself is
    /// unchanged. (Reading never runs this — hand-edited files still load.)
    static func appendValidationFailure(for session: FocusSessionLog) -> DailyLogError? {
        let spanSeconds = exactSpanSeconds(from: session.startedAt, to: session.endedAt)
        // Issue #27 amendment: ONE check, changed from
        // `spanSeconds == (focused + paused) * 60` to the minute-granularity
        // comparison documented above. Nothing else about this check changed.
        guard
            nearestMinute(spanSeconds)
                == session.focusedDuration + session.pausedDuration
        else {
            return .sessionArithmeticMismatch(
                sessionID: session.sessionID,
                startedAt: DailyLogDay.timestampString(from: session.startedAt),
                endedAt: DailyLogDay.timestampString(from: session.endedAt),
                focusedMinutes: session.focusedDuration,
                pausedMinutes: session.pausedDuration,
                spanSeconds: spanSeconds)
        }
        return nil
    }

    /// Whole-minute nearest rounding (half away from zero, the #12 engine
    /// rule) of an exact second count — the granularity of the #27 session
    /// amendment. The break check below stays exact (#27 changes only this
    /// session check; the break engine reconciles `ended_at` to
    /// `started_at + duration` minutes, so breaks are always minute-aligned).
    private static func nearestMinute(_ seconds: Int) -> Int {
        Int((Double(seconds) / 60).rounded(.toNearestOrAwayFromZero))
    }

    /// The append-time arithmetic check for a break:
    /// `ended_at − started_at` must exactly equal `duration` minutes.
    static func appendValidationFailure(for breakLog: BreakLog) -> DailyLogError? {
        let spanSeconds = exactSpanSeconds(from: breakLog.startedAt, to: breakLog.endedAt)
        guard spanSeconds == breakLog.duration * 60 else {
            return .breakArithmeticMismatch(
                breakID: breakLog.breakID,
                startedAt: DailyLogDay.timestampString(from: breakLog.startedAt),
                endedAt: DailyLogDay.timestampString(from: breakLog.endedAt),
                durationMinutes: breakLog.duration,
                spanSeconds: spanSeconds)
        }
        return nil
    }

    /// Whole-second span; `isFinite` guard keeps the `Int` conversion total
    /// (house style: nothing traps). Non-finite spans can never validate.
    private static func exactSpanSeconds(from startedAt: Date, to endedAt: Date) -> Int {
        let interval = endedAt.timeIntervalSince(startedAt)
        return interval.isFinite ? Int(interval) : 0
    }
}

// MARK: - Serialization

extension DailyLogCodec {
    /// Serializes the day's entries plus the opaque body into the canonical
    /// file format (byte-identical to the fixture for fixture content):
    ///
    ///     ---
    ///     sessions:                 ← always present ([] when empty)
    ///       - session_id: …         ← entries in fixture key order,
    ///         task_id: …              `- key: value` inline, continuations
    ///         …                       indented four spaces
    ///     breaks:                   ← always present ([] when empty)
    ///       - break_id: …
    ///     ---
    ///     <body, byte-for-byte>
    ///
    /// See the type-level documentation for the pinned serialization rules.
    public static func encodeDay(
        sessions: [FocusSessionLog], breaks: [BreakLog], body: String
    ) -> String {
        var lines: [String] = []
        if sessions.isEmpty {
            lines.append("sessions: []")
        } else {
            lines.append("sessions:")
            lines.append(contentsOf: sessions.flatMap(sessionLines))
        }
        if breaks.isEmpty {
            lines.append("breaks: []")
        } else {
            lines.append("breaks:")
            lines.append(contentsOf: breaks.flatMap(breakLines))
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    private static func sessionLines(_ session: FocusSessionLog) -> [String] {
        var lines = [
            "  - session_id: \(session.sessionID.uuidString.lowercased())",
            "    task_id: \(session.taskID.uuidString.lowercased())",
            "    started_at: \(DailyLogDay.timestampString(from: session.startedAt))",
            "    ended_at: \(DailyLogDay.timestampString(from: session.endedAt))",
            "    focused_duration: \(session.focusedDuration)",
            "    pause_count: \(session.pauseCount)",
            "    paused_duration: \(session.pausedDuration)",
            "    focus_rating: \(session.focusRating)",
            "    energy_rating: \(session.energyRating)",
            "    task_completed: \(session.taskCompleted ? "true" : "false")",
        ]
        if let notes = session.notes {
            lines.append("    notes: \(scalar(notes))")
        }
        return lines
    }

    private static func breakLines(_ breakLog: BreakLog) -> [String] {
        [
            "  - break_id: \(breakLog.breakID.uuidString.lowercased())",
            "    started_at: \(DailyLogDay.timestampString(from: breakLog.startedAt))",
            "    ended_at: \(DailyLogDay.timestampString(from: breakLog.endedAt))",
            "    duration: \(breakLog.duration)",
        ]
    }

    /// Emits one free-form scalar in canonical form — a deliberate local
    /// mirror of `FrontmatterEncoder`'s private helper (existing #4 files must
    /// not be edited), so quoting semantics match exactly: empty strings are
    /// single-quoted, strings that YAML would resolve as a non-string scalar
    /// or that contain newlines/control characters are double-quoted,
    /// everything else is emitted by Yams' deterministic emitter (plain when
    /// safe, Unicode kept literal).
    private static func scalar(_ string: String) -> String {
        let style: Node.Scalar.Style
        if string.isEmpty {
            style = .singleQuoted // a bare empty plain scalar would re-parse as null
        } else if containsBreaksOrControls(string) || resolvesToNonStringTag(string) {
            style = .doubleQuoted
        } else {
            style = .any // let the emitter pick plain / quoted
        }
        do {
            let yaml = try Yams.serialize(
                node: Node(string, .implicit, style), width: -1, allowUnicode: true)
            return yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
        } catch {
            return doubleQuotedFallback(string)
        }
    }

    private static func containsBreaksOrControls(_ string: String) -> Bool {
        string.contains("\n")
            || string.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// True when Yams' resolver (the same one used on read) would tag the bare
    /// scalar as something other than a string — such strings are double-
    /// quoted so they re-parse as strings.
    private static func resolvesToNonStringTag(_ string: String) -> Bool {
        Node(string, .implicit).tag.rawValue != Tag.Name.str.rawValue
    }

    private static func doubleQuotedFallback(_ string: String) -> String {
        var escaped = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\x%02x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped + "\""
    }
}
