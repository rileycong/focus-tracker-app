import SwiftUI
import UniformTypeIdentifiers

/// The per-row drop target of the #18 drag reorder (PRD §8.4): a rendered row
/// accepts a drop and hands the dragged row's ID plus **this row's position in
/// its sibling list** — the destination index the pinned `ReorderArithmetic`
/// remove-then-insert semantics consume — to a main-actor handler that owns
/// the membership check and the one reorder pipeline (drag and keyboard are
/// the same pipeline, pinned).
///
/// **Scope of a drop (pinned, issue #18):** the delegate itself is plumbing;
/// the handler validates that the dragged ID belongs to the target row's own
/// sibling list — a task's (project, status) group or one parent's subtask
/// sibling list. A task belongs to exactly one group and a subtask to exactly
/// one sibling list, so membership proves the drop stayed in scope; a drop
/// carrying another group's/parent's ID is the pinned no-op. A non-row target
/// never reaches this delegate (no container-level drop target is attached),
/// which is the pinned no-op for out-of-scope drops as well.
struct RowDropDelegate: DropDelegate {
    /// This row's index in its sibling list (the current display order).
    let destinationIndex: Int
    /// Called on the main actor with the dragged ID extracted from the drop —
    /// *after* the drop is accepted. Main-actor-qualified (implicitly
    /// `Sendable`): the pasteboard load completes off-main and hops back here.
    let onDrop: @MainActor (_ draggedID: UUID, _ destinationIndex: Int) async -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        // Copy only the Sendable values into the escaping pasteboard-load
        // completion; the handler hops to the main actor to touch any state.
        let handler = onDrop
        let index = destinationIndex
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let draggedID = UUID(uuidString: string)
            else { return }
            Task { @MainActor in
                await handler(draggedID, index)
            }
        }
        return true
    }
}
