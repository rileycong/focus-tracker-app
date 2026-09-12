import SwiftUI
import UniformTypeIdentifiers

/// The add/edit/delete/reorder entry points a subtask tree exposes (issues
/// #17 + #18), wired by `TasksView` to the `AppModel` passthroughs
/// (`addSubtask` / `updateSubtask` / `deleteSubtask` / `reorderSubtasks`).
/// `add` receives the top-level task ID (whose file the write lands in) and
/// the parent subtask's ID — nil for a task-level add, the subtask's ID for a
/// nested add (#8 contract). `reorder` reorders one sibling list within the
/// same parent (#18): `parentSubtaskID` nil = the task's top-level subtask
/// list, non-nil = that subtask's children list, with the IDs in their new
/// order (an exact permutation). Non-Sendable by design: formed and invoked
/// on the main actor only.
struct SubtaskActions {
    let add: (_ taskID: UUID, _ parentSubtaskID: UUID?) -> Void
    let edit: (_ taskID: UUID, _ subtask: SubtaskItem) -> Void
    let delete: (_ taskID: UUID, _ subtask: SubtaskItem) async -> Void
    let reorder: (
        _ taskID: UUID, _ parentSubtaskID: UUID?, _ siblingIDsInNewOrder: [UUID]
    ) async -> Void
}

/// One node of a task's subtask tree (issue #17): title, subtle status dot
/// (the #15 `TaskRowView` dot language), priority/effort chips when set, and
/// the deadline when set — overdue rendered distinctly via the #15
/// `TasksGrouping.isOverdue` rule. The node renders its own children
/// recursively (indentation accumulates one level per depth — unbounded,
/// `SubtaskItem.children` is the only structure involved).
///
/// **Disclosure choice (documented):** a custom disclosure — a chevron
/// button plus conditionally rendered children — rather than SwiftUI's
/// `DisclosureGroup` itself. The #15 task row's tap-to-select gesture and a
/// `DisclosureGroup`'s label toggle would compete for the same click on
/// macOS; the custom chevron keeps selection and expansion independent.
/// Collapse state persists through the same `TasksViewModel`/
/// `CollapseStateStoring` path the #15 sections use (stable ID-based keys
/// via `TasksGrouping.subtaskCollapseKey`), not reinvented.
///
/// **No project/categories of own (pinned, PRD §5.4):** subtask rows show
/// neither — both are inherited from ancestors. Engineer's choice on the
/// inherited hint: **none is shown**. The tree renders nested directly
/// under the ancestor task row, which already carries the project/category
/// chips; repeating resolved values on every node would duplicate them
/// down the tree and work against the PRD §21 "dark, minimal, calm" row
/// language. The form states the inheritance explicitly instead.
struct SubtaskRowView: View {
    /// The top-level task the tree hangs under (addresses the parent file —
    /// #8 takes `(parent task ID, subtask ID)` paths).
    let taskID: UUID
    let subtask: SubtaskItem
    /// The sibling-list context this node renders in (#18): the IDs of the
    /// list, in current display order, and the parent whose list it is — nil
    /// for the task's top-level subtask list, the parent subtask's ID for any
    /// nested list. Drag/keyboard reorders stay within exactly this list
    /// (pinned); the moved node's subtree travels with it (#8 semantics).
    let parentSubtaskID: UUID?
    let siblingIDs: [UUID]
    let viewModel: TasksViewModel
    let actions: SubtaskActions

    @State private var confirmingDelete = false

    private var hasChildren: Bool { !subtask.children.isEmpty }

    private var collapseKey: String {
        TasksGrouping.subtaskCollapseKey(taskID: taskID, subtaskID: subtask.id)
    }

    private var isExpanded: Bool {
        viewModel.isExpanded(forKey: collapseKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if hasChildren && isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subtask.children) { child in
                        SubtaskRowView(
                            taskID: taskID, subtask: child,
                            parentSubtaskID: subtask.id,
                            siblingIDs: subtask.children.map(\.id),
                            viewModel: viewModel, actions: actions)
                    }
                }
                .padding(.leading, DesignTokens.spacingM)
            }
        }
    }

    private var row: some View {
        HStack(spacing: DesignTokens.spacingS) {
            if hasChildren {
                Button {
                    viewModel.toggleExpanded(forKey: collapseKey)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse subtasks" : "Expand subtasks")
            } else {
                // Keep titles aligned with sibling nodes that do disclose.
                Color.clear
                    .frame(width: DesignTokens.statusDotSize + 1, height: 1)
            }
            Circle()
                .fill(DesignTokens.statusColor(subtask.status))
                .frame(width: DesignTokens.statusDotSize, height: DesignTokens.statusDotSize)
                .accessibilityLabel(Text(subtask.status.rawValue))
            Text(subtask.title)
                .font(.body)
                .lineLimit(1)
            if hasChildren {
                Label(
                    "\(subtask.children.count)",
                    systemImage: "list.bullet.indent")
                    .font(DesignTokens.annotationFont)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.spacingM)
            if let priority = subtask.priority {
                chip(priority.rawValue)
                    .foregroundStyle(DesignTokens.priorityColor(priority))
            }
            if let effort = subtask.effort {
                chip(effort.rawValue)
                    .foregroundStyle(.secondary)
            }
            if let deadline = subtask.deadline {
                Text(deadline.formatted(date: .abbreviated, time: .omitted))
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(
                        TasksGrouping.isOverdue(deadline: deadline, now: .now)
                            ? DesignTokens.overdue
                            : Color.secondary)
            }
        }
        .padding(.vertical, DesignTokens.rowVerticalPadding)
        .padding(.horizontal, DesignTokens.spacingS)
        .contentShape(Rectangle())
        // #18 drag reorder: the drop target is this row; a drop lands the
        // dragged sibling at this row's position in this sibling list (see
        // `RowDropDelegate`). Cross-parent drops are the pinned no-op — the
        // membership check in the handler below rejects any ID outside
        // `siblingIDs`.
        .onDrag { NSItemProvider(object: subtask.id.uuidString as NSString) }
        .onDrop(
            of: [UTType.text],
            delegate: RowDropDelegate(
                destinationIndex: siblingIDs.firstIndex(of: subtask.id) ?? 0,
                onDrop: { draggedID, destinationIndex in
                    guard siblingIDs.contains(draggedID),
                        let newOrder = ReorderArithmetic.newOrder(
                            moving: draggedID, to: destinationIndex, in: siblingIDs)
                    else { return }
                    await actions.reorder(taskID, parentSubtaskID, newOrder)
                }))
        .contextMenu { contextMenu }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await actions.delete(taskID, subtask) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if TasksGrouping.descendantCount(of: subtask) > 0 {
                Text("The subtask and its whole subtree will be removed. This cannot be undone.")
            }
        }
    }

    // MARK: - Context menu (add / edit / delete / reorder, issues #17 + #18)

    @ViewBuilder
    private var contextMenu: some View {
        Button("Add Subtask…") {
            actions.add(taskID, subtask.id)
        }
        Button("Edit Subtask…") {
            actions.edit(taskID, subtask)
        }
        Button("Delete Subtask…", role: .destructive) {
            confirmingDelete = true
        }
        Divider()
        // Keyboard alternative for the sibling-list reorder (#18): a neighbor
        // swap through the same pipeline as drag. Typed no-op at the list
        // boundary (nil — never a wrap-around).
        Button("Move Up") {
            guard let newOrder = ReorderArithmetic.swapUp(subtask.id, in: siblingIDs)
            else { return }
            Task { await actions.reorder(taskID, parentSubtaskID, newOrder) }
        }
        Button("Move Down") {
            guard let newOrder = ReorderArithmetic.swapDown(subtask.id, in: siblingIDs)
            else { return }
            Task { await actions.reorder(taskID, parentSubtaskID, newOrder) }
        }
    }

    /// The delete confirmation: when the target has N > 0 descendants, the
    /// title says so ("… and its N subtasks") — the count comes from the
    /// tested `TasksGrouping.descendantCount(of:)` helper.
    private var deleteConfirmationTitle: String {
        let count = TasksGrouping.descendantCount(of: subtask)
        return count > 0
            ? "Delete “\(subtask.title)” and its \(count) subtasks?"
            : "Delete “\(subtask.title)”?"
    }

    /// A small capsule chip (priority, effort) — the `TaskRowView` language.
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.chipFont)
            .padding(.horizontal, DesignTokens.spacingS)
            .padding(.vertical, DesignTokens.spacingXS)
            .background(DesignTokens.chipBackground)
            .cornerRadius(DesignTokens.cornerRadius)
            .lineLimit(1)
    }
}
