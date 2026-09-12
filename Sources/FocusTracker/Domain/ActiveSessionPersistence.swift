import Foundation

// MARK: - Errors

/// Typed load failures for the active-session snapshot (issue #13
/// criterion 2). A corrupt snapshot must never silently masquerade as "no
/// session": the error is surfaced **after** the file has been quarantined,
/// so nothing is lost and the caller knows recovery was refused.
public enum ActiveSessionPersistenceError: Error, Equatable, Sendable {
    /// The snapshot file exists but is not decodable as an
    /// `ActiveSessionSnapshot`. The file has already been renamed out of the
    /// way (`.corrupt` quarantine, never overwriting an existing quarantine)
    /// and a subsequent `load()` returns `nil` — the snapshot is treated as
    /// absent. `path` is the quarantine path the corrupt bytes were moved to.
    case corruptSnapshot(path: String)
}

// MARK: - Protocol

/// Persistence seam for the single active-session snapshot (issue #13
/// criterion 2). Exactly one app-local file is involved; nothing under the
/// vault's `Tasks/` or `Logs/` is ever touched (criterion 6).
public protocol ActiveSessionPersistence: Sendable {
    /// Atomically persists the snapshot (temp file in same dir → rename via
    /// the #5 `AtomicFileWriter`): a crash mid-save can never corrupt the
    /// snapshot — the target always holds the old or the new complete file.
    /// Creates the storage directory on first save.
    func save(_ snapshot: ActiveSessionSnapshot) throws

    /// Loads the snapshot. Missing file → `nil` (no active session). Present
    /// but undecodable → quarantines the file and throws
    /// `ActiveSessionPersistenceError.corruptSnapshot` (never a silent `nil`).
    func load() throws -> ActiveSessionSnapshot?

    /// Removes the snapshot file. Clearing when no file exists is a
    /// documented no-op success (PRD §18: the end/clear path must never fail
    /// because nothing was saved).
    func clear() throws
}

// MARK: - File-backed implementation

/// File-backed `ActiveSessionPersistence`: one JSON document at
/// `<directory>/active-session.json`, defaulting to
/// `~/Library/Application Support/FocusTracker/` (directory auto-created on
/// first save; the injected `directory` exists for tests).
///
/// # Write path (atomic, PRD §18)
/// The snapshot is JSON-encoded and written through the #5
/// `AtomicFileWriter` (hidden temp file in the same directory, fsync, single
/// atomic rename). Save failures surface as the writer's typed
/// `AtomicFileWriterError` with the previous snapshot intact.
///
/// # Corrupt-file quarantine (PRD §18: no silent data loss)
/// A present-but-undecodable file is renamed to `active-session.json.corrupt`
/// for inspection — never overwriting an existing quarantine: further
/// corrupt files get unique numeric suffixes (`active-session.json.corrupt-2`,
/// `.corrupt-3`, …). The rename goes through `AtomicFileWriter.move`, whose
/// `renamex_np(RENAME_EXCL)` makes the never-overwrite guarantee race-proof.
/// After quarantining, `load()` throws `.corruptSnapshot` and the snapshot is
/// treated as absent for the recovery decision (#13 criterion 4).
///
/// # Delete path
/// `clear()` removes the snapshot file; a missing file (or missing directory)
/// is a no-op success, so the end/clear path never fails for lack of a save.
public struct FileActiveSessionPersistence: ActiveSessionPersistence {

    /// The real Application Support location (the default `directory`
    /// parameter). Resolves inside the app container under sandboxing.
    public static let defaultDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FocusTracker", isDirectory: true)

    /// The snapshot document's pinned file name (issue #13 criterion 2).
    static let snapshotFilename = "active-session.json"

    /// First quarantine name: `active-session.json.corrupt`. Further
    /// quarantines get `-2`, `-3`, … numeric suffixes.
    static let quarantineSuffix = ".corrupt"

    private let directory: URL
    private let writer: AtomicFileWriter

    /// - Parameters:
    ///   - directory: Storage directory; auto-created on first save. The
    ///     default is the real `~/Library/Application Support/FocusTracker/`.
    ///   - writer: The #5 atomic writer. Tests inject one with a failure hook
    ///     to exercise the atomic-save semantics; production uses the default.
    public init(
        directory: URL = FileActiveSessionPersistence.defaultDirectory,
        writer: AtomicFileWriter = AtomicFileWriter()
    ) {
        self.directory = directory
        self.writer = writer
    }

    public func save(_ snapshot: ActiveSessionSnapshot) throws {
        // Directory auto-created on first save (issue #13 criterion 2).
        // Failures surface as the underlying (typed Cocoa) error — nothing
        // is swallowed.
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try writer.write(data, to: snapshotFileURL)
    }

    public func load() throws -> ActiveSessionSnapshot? {
        let url = snapshotFileURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil  // missing file → nil (no active session)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Removed between the existence check and the read (concurrent
            // clear/quarantine): absent.
            return nil
        }
        do {
            return try JSONDecoder().decode(ActiveSessionSnapshot.self, from: data)
        } catch {
            // Present but undecodable — must NOT masquerade as "no session".
            // Quarantine for inspection, then surface the typed error.
            let quarantineURL = try quarantineCorruptFile(at: url)
            throw ActiveSessionPersistenceError.corruptSnapshot(
                path: quarantineURL.path(percentEncoded: false))
        }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path(percentEncoded: false))
        else {
            return  // documented no-op success when nothing is saved
        }
        do {
            try FileManager.default.removeItem(at: snapshotFileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return  // removed concurrently between the check and the unlink
        }
    }

    // MARK: Internals

    private var snapshotFileURL: URL {
        directory.appendingPathComponent(Self.snapshotFilename)
    }

    /// Renames the corrupt file out of the way to
    /// `active-session.json.corrupt`, or `.corrupt-2`, `.corrupt-3`, … when a
    /// quarantine already exists — never overwriting one (PRD §18). Uses the
    /// #5 `AtomicFileWriter.move` (`renamex_np(RENAME_EXCL)`): the
    /// not-overwrite guarantee holds even against concurrent quarantine
    /// attempts, and a failed move leaves the corrupt file untouched. The
    /// numbering is bounded (then a UUID fallback name, which cannot collide
    /// in practice) so no path ever retries indefinitely.
    private func quarantineCorruptFile(at url: URL) throws -> URL {
        for attempt in 1...1_000 {
            let name = attempt == 1
                ? Self.snapshotFilename + Self.quarantineSuffix
                : "\(Self.snapshotFilename)\(Self.quarantineSuffix)-\(attempt)"
            let candidate = directory.appendingPathComponent(name)
            do {
                try writer.move(from: url, to: candidate)
                return candidate
            } catch AtomicFileWriterError.destinationExists {
                continue  // quarantine name taken: try the next suffix
            }
        }
        let fallback = directory.appendingPathComponent(
            "\(Self.snapshotFilename)\(Self.quarantineSuffix)-\(UUID().uuidString)")
        try writer.move(from: url, to: fallback)
        return fallback
    }
}
