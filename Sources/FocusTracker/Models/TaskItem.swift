import Foundation

/// The top-level task type (PRD §6.1–§6.8, §7).
///
/// `title`, `categories` (at least one) and `status` are required at
/// construction; `project`, `priority`, `effort`, `deadline`, `notes` and
/// `order` are optional. Subtasks nest recursively via `subtasks`.
public struct TaskItem: Identifiable, Hashable, Sendable, Codable {
    /// Error thrown when a task is constructed without any category (PRD §6.3).
    public enum ValidationError: Error, Equatable, Sendable {
        case atLeastOneCategoryRequired
    }

    public let id: UUID
    public var title: String
    public var categories: [Category]
    public var status: TaskStatus
    public var project: Project?
    public var priority: Priority?
    public var effort: Effort?
    public var deadline: Date?
    public var notes: String?
    /// Manual ordering within the task's (project, status) group (PRD §8.4,
    /// issue #10). `nil` = unordered; unordered tasks display last, in
    /// filename-sorted inventory order. Only relative order within a group
    /// matters — absolute values are meaningless. Top-level tasks only;
    /// subtasks carry no `order` (their ordering is the file's list order).
    public var order: Int?
    public var subtasks: [SubtaskItem]

    /// Creates a task, enforcing at least one category (PRD §6.3).
    public init(
        id: UUID = UUID(),
        title: String,
        categories: [Category],
        status: TaskStatus = .toDo,
        project: Project? = nil,
        priority: Priority? = nil,
        effort: Effort? = nil,
        deadline: Date? = nil,
        notes: String? = nil,
        order: Int? = nil,
        subtasks: [SubtaskItem] = []
    ) throws {
        guard !categories.isEmpty else {
            throw ValidationError.atLeastOneCategoryRequired
        }
        self.id = id
        self.title = title
        self.categories = categories
        self.status = status
        self.project = project
        self.priority = priority
        self.effort = effort
        self.deadline = deadline
        self.notes = notes
        self.order = order
        self.subtasks = subtasks
    }
}

extension TaskItem {
    /// The effective project for the task or any nested subtask, resolved from
    /// ancestors at any depth (PRD §5.4/§7). For the task itself this is its
    /// own `project`; for a subtask it walks up to the nearest ancestor —
    /// always the top-level task, since only tasks carry projects.
    public func effectiveProject(of id: UUID) -> Project? {
        if id == self.id { return project }
        return chain(to: id) != nil ? project : nil
    }

    /// The effective categories for the task or any nested subtask, resolved
    /// from ancestors at any depth (PRD §5.4/§7).
    public func effectiveCategories(of id: UUID) -> [Category] {
        if id == self.id { return categories }
        return chain(to: id) != nil ? categories : []
    }

    /// Chain of subtasks from `subtasks` down to the subtask with `id`,
    /// or nil if no subtask with that ID exists.
    func chain(to id: UUID) -> [SubtaskItem]? {
        SubtaskItem.chain(to: id, in: subtasks)
    }
}
