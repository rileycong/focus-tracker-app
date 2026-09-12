import Foundation

/// The pure reorder arithmetic the #18 manual-ordering UI composes with the
/// #10 `TaskOrdering` persistence rules (PRD §8.4) — the part #10 deliberately
/// left to this UI: deriving the new full ordering from
/// `(sibling ID list, moved ID, destination index)` and the keyboard swap
/// derivations. Pure like `TaskOrdering` itself: inputs in, new values out,
/// no store, no disk, no UI state — so every output is unit-testable
/// (`ReorderArithmeticTests`).
///
/// **Destination-index semantics (pinned, issue #18):** the index in the
/// *current* display order where the moved row lands, applied as
/// **remove-then-insert** — the moved ID is removed from its current position
/// first, then inserted at the destination index (clamped to the shortened
/// list). Dropping onto the row currently at index `i` therefore lands the
/// dragged task at index `i`: moving up places it exactly where the target row
/// was; moving down places it directly after the target row; dropping onto the
/// moved row's own position is a no-op (identical ordering).
///
/// **Pinned UI wiring (issue #18):** drag and keyboard are one pipeline —
/// every entry point derives a new ordering here, then
/// `TaskOrdering.reorder(currentDisplayOrder:newOrder:currentOrders:)` turns
/// it into the changed-only `order` updates for tasks
/// (`VaultStore.applyOrdering`), or the ordering is handed to
/// `VaultStore.reorderSubtasks` for subtask sibling lists (a keyboard move is
/// just a reorder whose destination index comes from the neighbor via the swap
/// helpers below). There is **no optimistic local reorder**: the UI applies
/// the write through the store and re-renders from the store's already-synced
/// inventory (`AppModel.mirrorSyncedInventory(from:)`, the #16/#17 pattern) —
/// the write path is a handful of small-file atomic writes, so no optimistic
/// state is needed.
///
/// **Permutation guarantee (by construction):** every output is the input list
/// with elements only *reordered* — nothing added, removed, or duplicated —
/// so `TaskOrdering.reorder`'s and `reorderSubtasks`' exact-permutation
/// validation never fires on UI-derived input (asserted in tests against both
/// validators).
public enum ReorderArithmetic {

    /// The sibling list reordered by moving `movedID` to `destinationIndex`
    /// (remove-then-insert — see the type documentation). This is the
    /// generalized helper: the same arithmetic serves a task's
    /// (project, status) group display order and any subtask sibling list
    /// (`parentSubtaskID` nil or set, any depth).
    ///
    /// - Returns: The new full ordering, or **nil** (typed no-op) when
    ///   `movedID` is not in the list or `destinationIndex` is out of bounds —
    ///   a caller cannot form an invalid permutation through this helper.
    ///   Moving onto the moved row's own index yields the identical ordering
    ///   (a no-op, not nil).
    public static func newOrder<Element: Hashable>(
        moving movedID: Element, to destinationIndex: Int, in siblingIDs: [Element]
    ) -> [Element]? {
        guard let sourceIndex = siblingIDs.firstIndex(of: movedID),
            siblingIDs.indices.contains(destinationIndex)
        else { return nil }
        var reordered = siblingIDs
        reordered.remove(at: sourceIndex)
        reordered.insert(movedID, at: min(destinationIndex, reordered.count))
        return reordered
    }

    /// The sibling list with `movedID` swapped with its **predecessor** (move
    /// up). The keyboard alternative's derivation (⌘⇧↑ / context-menu Move
    /// Up): a swap is just a reorder whose destination index is the neighbor's.
    ///
    /// - Returns: The new ordering, or **nil** (typed no-op) when `movedID` is
    ///   already first (or not in the list) — never a wrap-around.
    public static func swapUp<Element: Hashable>(
        _ movedID: Element, in siblingIDs: [Element]
    ) -> [Element]? {
        guard let index = siblingIDs.firstIndex(of: movedID), index > 0 else { return nil }
        var reordered = siblingIDs
        reordered.swapAt(index, index - 1)
        return reordered
    }

    /// The sibling list with `movedID` swapped with its **successor** (move
    /// down) — the mirror of `swapUp`.
    ///
    /// - Returns: The new ordering, or **nil** (typed no-op) when `movedID` is
    ///   already last (or not in the list) — never a wrap-around.
    public static func swapDown<Element: Hashable>(
        _ movedID: Element, in siblingIDs: [Element]
    ) -> [Element]? {
        guard let index = siblingIDs.firstIndex(of: movedID),
            siblingIDs.indices.contains(index + 1)
        else { return nil }
        var reordered = siblingIDs
        reordered.swapAt(index, index + 1)
        return reordered
    }
}
