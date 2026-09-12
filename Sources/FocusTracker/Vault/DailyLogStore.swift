import Foundation

/// Store for the daily log files `Logs/YYYY-MM-DD.md` (issue #11, PRD §5.5,
/// §13, §14.4, §18): typed reads of a day's sessions/breaks, safe
/// read-modify-atomic-write appends, and the `sessions(for:on:)` helper that
/// #20 consumes for "Session N today".
///
/// **Store shape (engineer's choice, documented):** a *separate* actor next to
/// `VaultStore` rather than an extension of it. The task-side store carries
/// load-time inventory/staleness machinery that has no meaning for day files
/// (day appends always re-read the single target file fresh — see below), and
/// a dedicated actor keeps the daily-log concurrency contract self-contained.
/// It reuses the #4 codec (`FrontmatterCodec.split` inside `DailyLogCodec`)
/// and the #5 `AtomicFileWriter` as-is — no existing Vault file is modified.
///
/// **Concurrency strategy (pinned choice (a), documented):** the actor
/// isolates every read-modify-write cycle. `appendSession`/`appendBreak` run
/// entirely within one synchronous actor turn — read file, mutate, serialize,
/// write — with **no `await` between read and write**, so concurrent appends
/// to the same day file are strictly serialized and cannot lose entries
/// (last-wins per whole file, which #5 alone provides, is NOT sufficient for
/// appends: two interleaved read-modify-write cycles could each drop the
/// other's entry). The #5 writer still provides the atomic publication
/// guarantee (temp file in the target directory → single rename; a crash
/// leaves the old or the new complete file, never anything in between).
///
/// **Date convention (one place):** every date parameter is any instant on a
/// *local calendar day*; the target file is `Logs/YYYY-MM-DD.md` per
/// `DailyLogDay.fileName(for:)`, and timestamps are read/written through the
/// same `DailyLogDay` offset-less ISO 8601 convention. Read, append and the
/// helper all resolve dates identically.
///
/// **Reading:** `readDay(for:)` returns the parsed `DailyLog` in file order.
/// - Missing file → empty result (zero sessions, zero breaks), never an
///   error. The opaque body is deliberately *not* exposed here (documented:
///   bodies are an internal detail of the append path; the codec's
///   `ParsedDailyLog` carries it for byte-preserving callers).
/// - Any malformed file — unsplitable frontmatter, invalid YAML, unknown
///   keys, an entry missing/unparseable a required field, the path being a
///   directory, non-UTF-8 bytes — fails with a typed `DailyLogError`
///   (documented choice (a): strict read; see `DailyLogError` for why the #6
///   warning-skip pattern was not used here).
/// - Reading never enforces the append-time arithmetic invariant (pinned):
///   hand-edited files with inconsistent durations still load.
///
/// **Appending:** `appendSession(_:to:)` / `appendBreak(_:to:)`.
/// - **Validation first, then I/O:** the append-time arithmetic check
///   (`ended_at − started_at == focused + paused` minutes for sessions,
///   `== duration` for breaks) runs *before* anything is read or written; a
///   mismatch throws the typed error naming the inconsistent values and
///   NOTHING is written — not even a new file.
/// - Read-modify-atomic-write: the day file is re-read fresh on every append
///   (missing → empty day), the entry is appended at the END of its list
///   (existing entries keep their order — appends never reorder), the file is
///   re-serialized through `DailyLogCodec.encodeDay` with the body
///   re-attached byte-for-byte, and published via #5 `AtomicFileWriter`.
///   Byte-for-byte preservation of existing entries is achieved by round-trip
///   determinism: canonically-formatted files re-serialize to identical bytes
///   (proven by tests), so the unchanged entries survive the rewrite exactly.
///   (A hand-formatted file is normalized to canonical form on first append —
///   values, body and order preserved.)
/// - Missing `Logs/` directory (or vault root) is created on append
///   (`withIntermediateDirectories`) — a fresh vault gets its `Logs/` on the
///   first log. Creation failure surfaces typed via `writeFailed`.
/// - A day file created for an absent date is written in canonical format
///   with **an empty body** (documented choice: the file ends right after the
///   closing `---`, matching #7's "new files start with an empty body").
/// - Write failures surface as `DailyLogError.writeFailed` wrapping the
///   preserved #5 typed error.
public actor DailyLogStore {
    /// The configured vault location (`Logs/` lives directly inside it).
    public let vaultURL: URL

    /// The file-system writer used for every write (consumed as-is from #5).
    private let fileWriter = AtomicFileWriter()

    /// - Parameter vaultURL: the user-configurable vault location.
    public init(vaultURL: URL) {
        self.vaultURL = vaultURL
    }

    /// The vault's `Logs/` directory.
    public var logsDirectory: URL {
        vaultURL.appendingPathComponent("Logs", isDirectory: true)
    }

    /// The day file for `date`'s local calendar day (`Logs/YYYY-MM-DD.md`) —
    /// the same resolution every API of this store uses (see `DailyLogDay`).
    public func fileURL(for date: Date) -> URL {
        logsDirectory.appendingPathComponent(DailyLogDay.fileName(for: date))
    }

    // MARK: - Reading

    /// Reads the daily log for `date`'s local calendar day. Missing file →
    /// empty result (never an error); malformed file → typed `DailyLogError`
    /// (documented strict choice); reading does NOT enforce the arithmetic
    /// invariant (documented).
    public func readDay(for date: Date) throws -> DailyLog {
        try readDayFile(for: date).log
    }

    /// The sessions in `date`'s day file whose `task_id` matches `taskID`, in
    /// file order — the exact result whose count #20 consumes for
    /// "Session N today". (Documented helper choice: the single-day
    /// `sessions(for:on:)` shape; no cross-day aggregation is required by the
    /// issue, so none is provided.) Missing file → empty; malformed file →
    /// typed error, same as `readDay(for:)`.
    public func sessions(for taskID: UUID, on date: Date) throws -> [FocusSessionLog] {
        try readDay(for: date).sessions.filter { $0.taskID == taskID }
    }

    // MARK: - Appending

    /// Appends `session` at the END of the day file's `sessions:` list (PRD
    /// §13). See the type documentation for the full contract: arithmetic
    /// validation before any I/O (nothing written on failure), actor-serialized
    /// read-modify-atomic-write, existing entries + body preserved
    /// byte-for-byte, no reordering, canonical file creation for absent dates.
    public func appendSession(_ session: FocusSessionLog, to date: Date) throws {
        if let failure = DailyLogCodec.appendValidationFailure(for: session) {
            throw failure
        }
        let url = fileURL(for: date)
        let parsed = try readDayFile(at: url, fileName: url.lastPathComponent)
        var log = parsed.log
        log.sessions.append(session)
        try write(log: log, body: parsed.body, to: url)
    }

    /// Appends `breakLog` at the END of the day file's `breaks:` list (PRD
    /// §14.4: the actual timed duration is the field of record). Same
    /// contract as `appendSession(_:to:)`.
    public func appendBreak(_ breakLog: BreakLog, to date: Date) throws {
        if let failure = DailyLogCodec.appendValidationFailure(for: breakLog) {
            throw failure
        }
        let url = fileURL(for: date)
        let parsed = try readDayFile(at: url, fileName: url.lastPathComponent)
        var log = parsed.log
        log.breaks.append(breakLog)
        try write(log: log, body: parsed.body, to: url)
    }

    // MARK: - Internals

    /// Reads the day file for `date`, tolerating exactly one thing: a missing
    /// file (→ empty day, never an error). Everything else is typed failure.
    private func readDayFile(for date: Date) throws -> ParsedDailyLog {
        let url = fileURL(for: date)
        return try readDayFile(at: url, fileName: url.lastPathComponent)
    }

    private func readDayFile(at url: URL, fileName: String) throws -> ParsedDailyLog {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // Missing file → empty day (documented tolerance).
            return ParsedDailyLog(log: DailyLog(), body: "")
        }
        guard !isDirectory.boolValue else {
            throw DailyLogError.dayPathIsADirectory(path)
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch {
            throw DailyLogError.unreadableFile(
                fileName: fileName, reason: String(describing: error))
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw DailyLogError.nonUTF8Encoded(fileName)
        }
        return try DailyLogCodec.parseDay(text)
    }

    /// Serializes `log` with `body` re-attached byte-for-byte and publishes it
    /// atomically. Called only from within one synchronous actor turn, after
    /// the fresh read — this closure-free read→mutate→write sequence is what
    /// makes concurrent appends lossless (documented concurrency strategy).
    private func write(log: DailyLog, body: String, to url: URL) throws {
        try ensureLogsDirectory()
        let text = DailyLogCodec.encodeDay(
            sessions: log.sessions, breaks: log.breaks, body: body)
        do {
            try fileWriter.write(Data(text.utf8), to: url)
        } catch let error as AtomicFileWriterError {
            throw DailyLogError.writeFailed(error)
        }
    }

    /// Creates `Logs/` (and any missing parents) when absent so the first log
    /// in a fresh vault works; an existing directory is left untouched.
    private func ensureLogsDirectory() throws {
        let path = logsDirectory.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return
        }
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
        } catch {
            throw DailyLogError.directoryCreationFailed(
                path: path, reason: String(describing: error))
        }
    }
}
