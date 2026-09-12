import Foundation

/// Errors synthesized by `VaultStore` itself: inventory building while
/// loading (issue #6, PRD §18) and the write side (issue #7, PRD §5.3, §6.5,
/// §18). Load errors never abort a load — each is reported inside a
/// `VaultStore.LoadWarning` (as `underlyingError`) and the rest of the vault
/// still loads. Write errors abort exactly the one operation that failed and
/// surface to the caller as thrown errors; on any typed write failure the
/// on-disk files are untouched or complete. All cases are `Equatable`
/// (mirroring the codec's `FrontmatterError` and the #5
/// `AtomicFileWriterError` conventions) so tests can assert exact cases, and
/// `Sendable` so errors can cross concurrency domains.
public enum VaultStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Two task files declare the same top-level task ID. `firstFile` names the
    /// filename-sorted winner; the skipped file is named by the warning's
    /// `LoadWarning.fileName`.
    case duplicateTaskID(id: UUID, firstFile: String)
    /// A subdirectory inside `Tasks/` was found and ignored. The vault schema
    /// is flat (one Markdown file per top-level task, nested subtasks live
    /// inside the parent file), so nothing inside the directory was read.
    case subdirectoryIgnored(String)
    /// A `.md` file was read but is not valid UTF-8, so it cannot be parsed as
    /// a task file. Reported inside a `LoadWarning` (PRD §18: skipped and
    /// surfaced, never silently accepted).
    case nonUTF8Encoded(String)

    // MARK: Write side (issue #7)

    /// `create` was handed an ID that is already loaded. Duplicate IDs are
    /// silently dropped at the next load (the filename-sorted winner rule),
    /// so accepting a second file for a loaded ID would lose data (PRD §18).
    case duplicateTaskIDOnCreate(UUID)
    /// A write operation targeted an ID that is not loaded: never loaded,
    /// already deleted, or a stale reference invalidated by a reload.
    case unknownTaskID(UUID)
    /// The ID belongs to a subtask, which lives inside its parent task's file
    /// and has no file of its own — status write-through is top-level only
    /// (§6.5); subtask-specific writes are #8.
    case notTopLevelTask(UUID)
    /// The staleness guard (issue #7, pinned: content compare, not mtime)
    /// found that the file's current bytes no longer match the bytes recorded
    /// at load — or the file has vanished entirely. The vault changed on disk
    /// between load and write; nothing was written and the inventory/mapping
    /// are untouched. The caller's recovery path is `load()`, then retry.
    case vaultChangedExternally(id: UUID, fileName: String)
    /// `rename`'s destination slug already belongs to a different file.
    /// Deliberately asymmetric with create (pinned decision, issue #7):
    /// create is additive and resolves collisions with a `-2`/`-3` suffix
    /// probe, while rename can destroy an existing file, so it fails loudly
    /// and the caller decides. Both files are untouched.
    case renameDestinationExists(String)
    /// Create's bounded collision probe found the slug and every probed
    /// `-2`…`-1001` suffix taken. Astronomically unlikely; surfaced instead of
    /// probing forever (same "no indefinite retries" stance as #5).
    case noFreeFileName(stem: String)
    /// An `AtomicFileWriter` operation failed; the underlying #5 typed error
    /// is preserved unchanged (`directoryMissing`, `fileMissing`,
    /// `destinationExists`, `renameFailed`, `posixError`, …) so callers can
    /// react to specific OS conditions such as a temporarily unavailable vault
    /// or a missing `Tasks/` directory (PRD §18) — never a crash, never a
    /// partial write.
    case writeFailed(AtomicFileWriterError)

    public var description: String {
        switch self {
        case .duplicateTaskID(let id, let firstFile):
            return "duplicate task ID \(id.uuidString); filename-sorted winner: \(firstFile)"
        case .subdirectoryIgnored(let name):
            return "subdirectory inside Tasks/ ignored: \(name)"
        case .nonUTF8Encoded(let name):
            return "file is not valid UTF-8, cannot parse as a task: \(name)"
        case .duplicateTaskIDOnCreate(let id):
            return "create refused: task ID \(id.uuidString) is already loaded"
        case .unknownTaskID(let id):
            return "no loaded task with ID \(id.uuidString)"
        case .notTopLevelTask(let id):
            return "ID \(id.uuidString) belongs to a subtask; only top-level tasks are written directly"
        case .vaultChangedExternally(let id, let fileName):
            return "\"\(fileName)\" (task \(id.uuidString)) changed on disk since load; nothing was written — reload and retry"
        case .renameDestinationExists(let name):
            return "rename destination already belongs to a different file: \(name)"
        case .noFreeFileName(let stem):
            return "no free filename for \"\(stem)\" after the bounded collision probe"
        case .writeFailed(let underlying):
            return "atomic file operation failed: \(underlying)"
        }
    }
}
