import Foundation

/// Errors synthesized by `VaultStore` itself: inventory building while
/// loading (issue #6, PRD §18), the write side (issue #7, PRD §5.3, §6.5,
/// §18) and the path-based subtask CRUD (issue #8, PRD §5.4, §7). Load errors
/// never abort a load — each is reported inside a
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

    // MARK: Subtask writes (issue #8)

    /// A subtask operation addressed a subtask ID that does not exist anywhere
    /// in the parent task's recursive subtask tree — at any depth, including
    /// an unknown `toParentSubtaskID` target for `addSubtask` and an unknown
    /// `parentSubtaskID` for `reorderSubtasks`. `parentTaskID` is the
    /// top-level task the operation was addressed through. (The task's own ID
    /// is not a subtask address either.)
    case unknownSubtaskID(subtaskID: UUID, parentTaskID: UUID)
    /// `addSubtask` was handed a subtask whose ID already exists in the parent
    /// file — the task's own ID or any subtask ID at any depth, across
    /// different subtask parents. Fail-loud, matching
    /// `.duplicateTaskIDOnCreate`'s stance: silently regenerating the ID would
    /// leave the caller holding a different ID than the one it passed
    /// (PRD §18: no silent data acceptance). Nothing is written.
    case duplicateSubtaskIDOnAdd(subtaskID: UUID, parentTaskID: UUID)
    /// `reorderSubtasks` was handed a sibling order that is not an exact
    /// permutation of the targeted sibling list's current IDs — an ID is
    /// missing, extra, or duplicated. `currentSiblings` is the list as
    /// currently stored (list order = file order), `proposedOrder` the
    /// rejected order. Nothing is written.
    case reorderNotExactPermutation(currentSiblings: [UUID], proposedOrder: [UUID])

    // MARK: Manual task ordering (issue #10)

    /// `applyOrdering(groupUpdates:)` failed partway through its batch. PRD §18
    /// atomicity is **per file** and each task is its own file, so the batch is
    /// deliberately *not* cross-file atomic: some task files may already carry
    /// their new order. `completed` names the files that were fully written and
    /// inventory-synced (ID → filename, in application order); `pending` names
    /// the tasks whose files were **not** written by this batch — the failing
    /// task itself (its whole-file write is atomic, so the file is untouched)
    /// and every task not attempted. `underlying` is the #7-path error that
    /// aborted the batch (`.vaultChangedExternally`, `.writeFailed`, …). The
    /// caller's recovery path is `load()` (refreshes the staleness-guard
    /// records) then retrying the pending updates. (`indirect` on this case
    /// only — the recursion through `underlying` must not box every other
    /// error payload.)
    indirect case orderingBatchIncomplete(
        completed: [UUID: String], pending: [UUID: String], underlying: VaultStoreError)

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
        case .unknownSubtaskID(let subtaskID, let parentTaskID):
            return
                "no subtask with ID \(subtaskID.uuidString) in parent task \(parentTaskID.uuidString)"
        case .duplicateSubtaskIDOnAdd(let subtaskID, let parentTaskID):
            return
                "add refused: subtask ID \(subtaskID.uuidString) already exists in parent task \(parentTaskID.uuidString)"
        case .reorderNotExactPermutation(let currentSiblings, let proposedOrder):
            return
                "reorder refused: the proposed sibling order is not an exact permutation of the current list — current \(currentSiblings.map(\.uuidString)), proposed \(proposedOrder.map(\.uuidString))"
        case .orderingBatchIncomplete(let completed, let pending, let underlying):
            return
                "ordering batch incomplete: \(completed.count) file(s) written, \(pending.count) task(s) pending — not cross-file atomic, recover with load() + retry; underlying: \(underlying)"
        }
    }
}
