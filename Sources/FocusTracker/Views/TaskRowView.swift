import SwiftUI

/// A single task row of the Tasks view (issue #15; #17 extends it): title,
/// subtle status dot, priority/effort chips when set, deadline when set
/// (overdue rendered distinctly via `TasksGrouping.isOverdue`), category
/// labels, and the subtask tree indented beneath it.
///
/// **Subtask tree (issue #17):** when the task has subtasks, the row gains a
/// disclosure chevron and renders its subtask tree nested underneath —
/// recursively through `SubtaskRowView`, so depth is unbounded (a property
/// of `SubtaskItem.children`, not a UI limit). Disclosure uses the same
/// custom chevron + conditional children shape as `SubtaskRowView` (tap
/// stays selection per #15; see there for the documented reasoning), with
/// collapse state persisted through the shared `TasksViewModel`/
/// `CollapseStateStoring` path (`TasksGrouping.taskCollapseKey`).
///
/// Read-only other than selection and the disclosure: #16 edit / #19 start
/// attach later; subtask add/edit/delete live in the rows' context menus.
struct TaskRowView: View {
    let task: TaskItem
    let viewModel: TasksViewModel
    /// The subtask entry points handed down to the tree's rows (issue #17).
    let subtaskActions: SubtaskActions

    private var hasSubtasks: Bool { !task.subtasks.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.tasksRowSpacing) {
            row
            if hasSubtasks
                && viewModel.isExpanded(forKey: TasksGrouping.taskCollapseKey(task.id))
            {
                VStack(alignment: .leading, spacing: DesignTokens.tasksRowSpacing) {
                    ForEach(task.subtasks) { subtask in
                        SubtaskRowView(
                            taskID: task.id, subtask: subtask,
                            parentSubtaskID: nil,
                            siblingIDs: task.subtasks.map(\.id),
                            viewModel: viewModel, actions: subtaskActions)
                    }
                }
                .padding(.leading, DesignTokens.tasksSubtaskIndent)
            }
        }
    }

    private var row: some View {
        HStack(spacing: DesignTokens.spacingS) {
            if hasSubtasks {
                Button {
                    viewModel.toggleExpanded(forKey: TasksGrouping.taskCollapseKey(task.id))
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(
                            size: DesignTokens.tasksChevronIconSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(
                            .degrees(
                                viewModel.isExpanded(
                                    forKey: TasksGrouping.taskCollapseKey(task.id)) ? 90 : 0))
                }
                .buttonStyle(.plain)
                .help(
                    viewModel.isExpanded(forKey: TasksGrouping.taskCollapseKey(task.id))
                        ? "Collapse subtasks" : "Expand subtasks")
            }
            Circle()
                .fill(DesignTokens.statusColor(task.status))
                .frame(
                    width: DesignTokens.tasksStatusDotSize,
                    height: DesignTokens.tasksStatusDotSize)
                .accessibilityLabel(Text(task.status.rawValue))
            Text(task.title)
                .font(DesignTokens.tasksParentTitleFont)
                .lineLimit(1)
            if hasSubtasks {
                Label(
                    "\(task.subtasks.count)",
                    systemImage: "list.bullet.indent")
                    .font(DesignTokens.tasksMetadataFont)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.spacingM)
            if let priority = task.priority {
                chip(priority.rawValue)
                    .foregroundStyle(DesignTokens.priorityColor(priority))
            }
            if let effort = task.effort {
                chip(effort.rawValue)
                    .foregroundStyle(.secondary)
            }
            if let deadline = task.deadline {
                Text(deadline.formatted(date: .abbreviated, time: .omitted))
                    .font(DesignTokens.tasksMetadataFont)
                    .foregroundStyle(
                        TasksGrouping.isOverdue(deadline: deadline, now: .now)
                            ? DesignTokens.overdue
                            : Color.secondary)
            }
            ForEach(task.categories, id: \.name) { category in
                chip(category.name)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DesignTokens.tasksRowVerticalPadding)
        .padding(.horizontal, DesignTokens.spacingS)
        .background(
            viewModel.isSelected(task.id)
                ? DesignTokens.selectionBackground
                : Color.clear)
        .cornerRadius(DesignTokens.cornerRadius)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggleSelection(of: task.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(
            viewModel.isSelected(task.id) ? AccessibilityTraits.isSelected : [])
    }

    /// A small capsule chip (priority, effort, category).
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.tasksChipFont)
            .padding(.horizontal, DesignTokens.spacingS)
            .padding(.vertical, DesignTokens.spacingXS)
            .background(DesignTokens.chipBackground)
            .cornerRadius(DesignTokens.cornerRadius)
            .lineLimit(1)
    }
}
