import SwiftUI

/// A single task row of the Tasks view (issue #15). Read-only: the only
/// interaction is selection (visual only — #16 edit / #19 start attach later).
///
/// Content per the issue: title, subtle status dot, priority/effort chips
/// when set, deadline when set (overdue rendered distinctly via
/// `TasksGrouping.isOverdue`), category labels, and a simple subtask-count
/// indicator.
struct TaskRowView: View {
    let task: TaskItem
    let viewModel: TasksViewModel

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Circle()
                .fill(DesignTokens.statusColor(task.status))
                .frame(width: DesignTokens.statusDotSize, height: DesignTokens.statusDotSize)
                .accessibilityLabel(Text(task.status.rawValue))
            Text(task.title)
                .font(.body)
                .lineLimit(1)
            if !task.subtasks.isEmpty {
                Label(
                    "\(task.subtasks.count)",
                    systemImage: "list.bullet.indent")
                    .font(DesignTokens.annotationFont)
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
                    .font(DesignTokens.annotationFont)
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
        .padding(.vertical, DesignTokens.rowVerticalPadding)
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
            .font(DesignTokens.chipFont)
            .padding(.horizontal, DesignTokens.spacingS)
            .padding(.vertical, DesignTokens.spacingXS)
            .background(DesignTokens.chipBackground)
            .cornerRadius(DesignTokens.cornerRadius)
            .lineLimit(1)
    }
}
