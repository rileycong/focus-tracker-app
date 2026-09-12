/// Allowed statuses for tasks and subtasks (PRD §6.5).
///
/// Raw values exactly match the strings persisted in `fixtures/sample-vault/`.
public enum TaskStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case toDo = "To Do"
    case inProgress = "In Progress"
    case blocked = "Blocked"
    case dropped = "Dropped"
    case done = "Done"
}

/// Optional planning priority (PRD §6.6).
public enum Priority: String, Codable, Sendable, CaseIterable, Hashable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

/// Optional estimated-effort bucket, treated as an ordinal planning signal (PRD §6.7).
public enum Effort: String, Codable, Sendable, CaseIterable, Hashable {
    case s = "S"
    case m = "M"
    case l = "L"
    case xl = "XL"
}
