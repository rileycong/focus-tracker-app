import Foundation

/// `VaultStore` convenience wrappers for the #9 status transitions (PRD §6.5,
/// §8.6, §12.1): `startSession`, `complete`, `unblock`, `drop`, `restore`.
///
/// **Thin by construction:** each wrapper resolves the target through the
/// existing inventory `lookup(_:)`, runs the pure `StatusTransition` decision
/// over the owning task tree, and — only when the decision is an allowed,
/// non-empty change set — applies the writes through the **existing #7/#8
/// operations**. The wrappers perform no file I/O of their own and add no new
/// persistence mechanisms:
///
/// - A **single-ID** change rides the pinned per-ID paths: top-level targets
///   through `setStatus(_:to:)` (#7), subtask targets through
///   `setStatus(parentID:subtaskID:to:)` (#8) — a whole-parent-file rewrite.
/// - A **multi-ID** change set (only `complete` can produce one, by bubbling
///   up through ancestors) is applied to one copy of the parent tree via the
///   pure `TaskItem.applying(status:to:)` and persisted with **one** `update`
///   (#7) — the affected top-level task's file is rewritten exactly once,
///   not once per changed ID.
///
/// Every write therefore carries the #7 guarantees unchanged: the
/// reload-before-write staleness guard (`.vaultChangedExternally`, recover by
/// `load()` then retry), the atomic temp+rename write, the body preserved
/// byte-for-byte, and the in-place inventory sync after success. Typed errors
/// surface unchanged (`VaultStoreError`): an unknown ID throws
/// `.unknownTaskID`, an unavailable vault `.writeFailed(.directoryMissing)`,
/// an externally changed file `.vaultChangedExternally` — with nothing
/// written.
///
/// **Refusals and no-ops are returned, not thrown:** a refused decision
/// (`.refused(.blocked/.dropped/.alreadyDone)`) and a legitimate no-op
/// (`.transitioned([])`, e.g. starting a session on an In-Progress task)
/// leave disk and inventory untouched and are handed back as the typed
/// `StatusTransition.Outcome` — never a crash, never a silent divergence.
extension VaultStore {

    /// Starts a focus session on the task or subtask (PRD §6.5, timer flow
    /// #19): `To Do` moves to `In Progress`; `In Progress` is an allowed
    /// no-op; `Blocked`/`Dropped`/`Done` are refused with the pinned reason.
    ///
    /// For the §8.6 ad-hoc path the caller constructs the `TaskItem` with
    /// `.inProgress` and creates it via the existing `create(_:)` (decision
    /// documented on `StatusTransition`); `startSession` on such a task is
    /// then the pinned no-op.
    ///
    /// - Returns: The typed decision outcome. Nothing is written unless the
    ///   outcome is `.transitioned` with a non-empty set.
    /// - Throws: The existing `VaultStoreError` cases unchanged (unknown ID
    ///   → `.unknownTaskID`; unavailable vault → `.writeFailed`; externally
    ///   changed file → `.vaultChangedExternally`, nothing written).
    @discardableResult
    public func startSession(_ id: UUID) throws -> StatusTransition.Outcome {
        try transition(id, to: .inProgress) { StatusTransition.startSession(of: id, in: $0) }
    }

    /// Completes the task or subtask and applies recursive parent completion
    /// (PRD §6.5): the target becomes `Done` and every ancestor whose
    /// children are all `Done` becomes `Done` in the same derived set —
    /// persisted as at most **one** whole-file rewrite of the owning
    /// top-level task. An already-`Done` target is the empty no-op set; the
    /// decision is allowed from any status (see `StatusTransition.complete`).
    ///
    /// - Returns/-Throws: As documented on the extension.
    @discardableResult
    public func complete(_ id: UUID) throws -> StatusTransition.Outcome {
        try transition(id, to: .done) { StatusTransition.complete(id, in: $0) }
    }

    /// Unblocks the task or subtask: `Blocked` → `To Do`, only via this
    /// explicit operation. Unblocking a node that is not `Blocked` is the
    /// empty no-op set.
    ///
    /// - Returns/-Throws: As documented on the extension.
    @discardableResult
    public func unblock(_ id: UUID) throws -> StatusTransition.Outcome {
        try transition(id, to: .toDo) { StatusTransition.unblock(id, in: $0) }
    }

    /// Drops the task or subtask: any active status (`To Do`, `In Progress`,
    /// `Blocked`) → `Dropped`. Dropping an already-`Dropped` node is the
    /// empty no-op set; dropping a `Done` node is refused `.alreadyDone`.
    ///
    /// - Returns/-Throws: As documented on the extension.
    @discardableResult
    public func drop(_ id: UUID) throws -> StatusTransition.Outcome {
        try transition(id, to: .dropped) { StatusTransition.drop(id, in: $0) }
    }

    /// Restores the task or subtask: `Dropped` → `To Do` — never directly
    /// `In Progress` (a later `startSession` moves it onward). Restoring a
    /// node that is not `Dropped` is the empty no-op set.
    ///
    /// - Returns/-Throws: As documented on the extension.
    @discardableResult
    public func restore(_ id: UUID) throws -> StatusTransition.Outcome {
        try transition(id, to: .toDo) { StatusTransition.restore(id, in: $0) }
    }

    // MARK: - Shared path

    /// Resolves `id` through the inventory, runs the pure decision over the
    /// owning tree, and applies an allowed non-empty change set through the
    /// existing #7/#8 write path. Refusals and empty change sets write
    /// nothing and are returned as-is.
    private func transition(
        _ id: UUID,
        to targetStatus: TaskStatus,
        decide: (TaskItem) -> StatusTransition.Outcome
    ) throws -> StatusTransition.Outcome {
        let (tree, isTopLevel) = try owningTree(for: id)
        let outcome = decide(tree)
        guard case .transitioned(let changed) = outcome, !changed.isEmpty else {
            return outcome
        }

        if changed == [id] {
            // Single-ID change: the pinned per-ID paths (#7 top-level,
            // #8 subtask — a whole-parent-file rewrite either way).
            if isTopLevel {
                _ = try setStatus(id, to: targetStatus)
            } else {
                _ = try setStatus(parentID: tree.id, subtaskID: id, to: targetStatus)
            }
        } else {
            // Multi-ID change set (complete's bubble-up): apply every changed
            // status to one copy of the parent tree and rewrite the ONE
            // affected top-level file exactly once via the #7 update path
            // (staleness guard, atomic write, body preserved) — never once
            // per changed ID.
            _ = try update(tree.applying(status: targetStatus, to: changed))
        }
        return outcome
    }

    /// The top-level task whose file owns `id`, and whether `id` is that task
    /// itself. Resolution is inventory-only (`lookup(_:)`, never re-derived
    /// from a title); an unloaded ID fails with the existing `.unknownTaskID`.
    private func owningTree(for id: UUID) throws -> (tree: TaskItem, isTopLevel: Bool) {
        switch lookup(id) {
        case .task(let task):
            return (task, true)
        case .subtask(_, let parent):
            return (parent, false)
        case .notFound:
            throw VaultStoreError.unknownTaskID(id)
        }
    }
}
