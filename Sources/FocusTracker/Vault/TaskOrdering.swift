import Foundation

/// Pure manual-task-ordering helpers (issue #10, PRD §8.4): the display-order
/// rule and the reorder renumbering. Both are pure — inputs in, new values out,
/// nothing touches the store or the disk — so `VaultStore` and the #18 UI
/// compose them freely and every behavior is unit-testable (same spirit as #8's
/// pure `[SubtaskItem]` helpers and #3's model helpers). They live in `Vault/`
/// (not `Models/`) because they encode store-side persistence semantics, and
/// `Models/` stays frozen apart from the `TaskItem.order` field.
///
/// **Pinned rules (issue #10):**
/// - A task's group is its **(project, status)** pair; ordering only ever
///   matters within one group. Cross-group moves are a #9 status update plus an
///   ordering update — not this API.
/// - **Display order:** within one group, tasks sort by
///   `(order ?? Int.max, filename-sorted inventory position)` — ordered tasks
///   first (ascending `order`), unordered last in the filename-sorted order the
///   #6 inventory provides, equal `order` values tie-breaking by that same
///   position. Consequence: a group with no `order` values at all displays
///   exactly as it does today.
/// - **Renumbering:** after a reorder the whole group is renumbered
///   contiguously `0…n-1` in the new display order (can never collide with the
///   `Int.max` unordered sentinel, and gaps never accumulate). Any-`Int`
///   values from hand-edited files are legal input; they just get renumbered.
public enum TaskOrdering {
    /// A task group: the (project, status) pair that manual ordering is scoped
    /// to (PRD §8.4). `nil` project = the no-project group.
    public struct Group: Hashable, Sendable {
        public let project: Project?
        public let status: TaskStatus

        public init(project: Project?, status: TaskStatus) {
            self.project = project
            self.status = status
        }
    }

    /// Resolves every group's display order per the pinned rule above.
    ///
    /// `tasks` must be the task list in **filename-sorted inventory order** (as
    /// `VaultStore.tasks` provides); that input position is both the
    /// unordered-tasks fallback order and the tie-break for equal `order`
    /// values. Membership is derived from each task's own `project` and
    /// `status`. Deterministic for identical input: the position tie-break
    /// makes the comparator total, so the result does not depend on sort
    /// stability.
    ///
    /// - Returns: Each group's task IDs in display order.
    public static func displayOrder(of tasks: [TaskItem]) -> [Group: [UUID]] {
        var members: [Group: [(position: Int, id: UUID, order: Int?)]] = [:]
        for (position, task) in tasks.enumerated() {
            members[Group(project: task.project, status: task.status), default: []]
                .append((position, task.id, task.order))
        }
        var result: [Group: [UUID]] = [:]
        for (group, groupMembers) in members {
            result[group] = groupMembers
                .sorted { ($0.order ?? .max, $0.position) < ($1.order ?? .max, $1.position) }
                .map(\.id)
        }
        return result
    }

    /// Computes the changed-only `order` updates for one group reorder — the
    /// pure core behind `VaultStore.applyOrdering(groupUpdates:)` (issue #10).
    ///
    /// - Parameters:
    ///   - currentDisplayOrder: The group's task IDs in their current display
    ///     order (`TaskOrdering.displayOrder`'s output for the group).
    ///   - newOrder: The proposed new full ordering of the same group.
    ///   - currentOrders: The group's currently persisted `order` values
    ///     (`nil` = unordered); IDs without an entry count as unordered.
    /// - Returns: Only the tasks whose new contiguous `0…n-1` index differs
    ///   from their currently persisted value, mapped to the new value. An
    ///   unordered task becoming ordered always counts as changed (`nil` never
    ///   equals a `0…n-1` index); a no-op ordering yields an empty map.
    ///   Deriving `newOrder` from (moved ID, destination index) is trivial
    ///   arithmetic left to the #18 UI.
    /// - Throws: `VaultStoreError.reorderNotExactPermutation` when `newOrder`
    ///   is not an exact permutation of `currentDisplayOrder` — missing, extra,
    ///   or duplicated IDs. Nothing is computed in that case.
    public static func reorder(
        currentDisplayOrder: [UUID],
        newOrder: [UUID],
        currentOrders: [UUID: Int?]
    ) throws -> [UUID: Int] {
        guard newOrder.count == currentDisplayOrder.count,
            Set(newOrder) == Set(currentDisplayOrder)
        else {
            throw VaultStoreError.reorderNotExactPermutation(
                currentSiblings: currentDisplayOrder, proposedOrder: newOrder)
        }
        var updates: [UUID: Int] = [:]
        for (index, id) in newOrder.enumerated() {
            // `[UUID: Int?]` subscript yields `Int??`; `?? nil` flattens it.
            if (currentOrders[id] ?? nil) != index {
                updates[id] = index
            }
        }
        return updates
    }
}
