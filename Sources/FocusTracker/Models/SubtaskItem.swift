import Foundation

/// A recursively nested subtask (PRD §5.4, §7).
///
/// Subtasks carry no `project`/`categories` of their own; those resolve from
/// ancestors (see `TaskItem.effectiveProject(of:)` /
/// `TaskItem.effectiveCategories(of:)`). The nested array is named `children`
/// in Swift but persists under the vault key `subtasks` to match
/// `fixtures/sample-vault/` exactly.
public struct SubtaskItem: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var title: String
    public var status: TaskStatus
    public var priority: Priority?
    public var effort: Effort?
    public var deadline: Date?
    public var notes: String?
    public var children: [SubtaskItem]

    public init(
        id: UUID = UUID(),
        title: String,
        status: TaskStatus = .toDo,
        priority: Priority? = nil,
        effort: Effort? = nil,
        deadline: Date? = nil,
        notes: String? = nil,
        children: [SubtaskItem] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.effort = effort
        self.deadline = deadline
        self.notes = notes
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status, priority, effort, deadline, notes
        case children = "subtasks"
    }
}

extension SubtaskItem {
    /// Returns the chain of subtasks from `candidates` down to (and including)
    /// the subtask with `id`, or nil if not found. Index 0 is the top-most
    /// subtask of the chain; the last element is the target.
    static func chain(to id: UUID, in candidates: [SubtaskItem]) -> [SubtaskItem]? {
        for subtask in candidates {
            if subtask.id == id { return [subtask] }
            if var deeper = chain(to: id, in: subtask.children) {
                deeper.insert(subtask, at: 0)
                return deeper
            }
        }
        return nil
    }
}
