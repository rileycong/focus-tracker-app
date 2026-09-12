import Foundation

/// The pure grouping/ordering core of the Tasks view (issue #15, PRD §8.2–§8.4):
/// `tasks` in filename-sorted inventory order plus the Done/Dropped filter
/// state in → the full collapsible section structure out. No UI, no state, no
/// I/O — the same spirit as `TaskOrdering` (#10), whose display-order rule this
/// uses verbatim, so every behavior below is unit-tested
/// (`TasksGroupingTests`).
///
/// **Pinned rules (issue #15 / PRD §8.3):**
/// - One section per project, **sorted by project name**; the `No Project`
///   section is **pinned last** and only present when at least one eligible
///   task has no project.
/// - Within each section, status sub-groups in the pinned order `To Do`,
///   `In Progress`, `Blocked` — **always present, even when empty** — plus
///   `Done` and `Dropped` only when the filter is on (the same pinned order,
///   appended).
/// - A section appears only when it has at least one **eligible** task:
///   with the filter off, `Done`/`Dropped` tasks are excluded from grouping
///   entirely (a done-only project shows no section until the filter is on).
/// - Within each status group, tasks are ordered exactly by the #10 rule
///   (`TaskOrdering.displayOrder`: `(order ?? Int.max, filename-sorted
///   inventory position)`), over the eligible task list.
///
/// The same file also hosts the overdue rule the row rendering uses, so it is
/// unit-tested like the rest of the pure logic.
public enum TasksGrouping {

    /// The status sub-groups every section always carries (PRD §8.3: the
    /// active groups), in the pinned display order.
    static let activeStatuses: [TaskStatus] = [.toDo, .inProgress, .blocked]

    /// The full pinned status order for a section: the active groups always,
    /// plus `Done`/`Dropped` appended when the filter is on.
    public static func statuses(showCompleted: Bool) -> [TaskStatus] {
        activeStatuses + (showCompleted ? [.done, .dropped] : [])
    }

    /// Builds the section structure (see the type documentation for the
    /// pinned rules). `tasks` must be the filename-sorted inventory order —
    /// exactly what `AppModel.tasks` exposes — because that position is the
    /// #10 ordering's fallback and tie-break.
    public static func sections(tasks: [TaskItem], showCompleted: Bool) -> [TaskSection] {
        let eligible = tasks.filter { showCompleted || activeStatuses.contains($0.status) }
        guard !eligible.isEmpty else { return [] }

        // The #10 display-order rule over the eligible list: (project, status)
        // → ordered IDs. IDs always come from `eligible`, so the lookup below
        // cannot miss.
        let displayOrder = TaskOrdering.displayOrder(of: eligible)
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })

        func groups(for project: Project?) -> [TaskStatusGroup] {
            statuses(showCompleted: showCompleted).map { status in
                let ids = displayOrder[TaskOrdering.Group(project: project, status: status)] ?? []
                return TaskStatusGroup(
                    status: status,
                    tasks: ids.compactMap { byID[$0] },
                    collapseKey: statusCollapseKey(project: project, status: status))
            }
        }

        let projects = Set(eligible.compactMap(\.project))
            .sorted { $0.name < $1.name }
            .map { Optional($0) }
        let projectSections = projects.map { project in
            TaskSection(
                project: project,
                groups: groups(for: project),
                collapseKey: projectCollapseKey(project))
        }

        guard eligible.contains(where: { $0.project == nil }) else {
            return projectSections
        }
        return projectSections + [
            TaskSection(
                project: nil,
                groups: groups(for: nil),
                collapseKey: projectCollapseKey(nil))
        ]
    }

    /// Overdue rule (#15, tested): a deadline **strictly before** `now` is
    /// overdue; a deadline exactly at `now` is due-now, not overdue.
    public static func isOverdue(deadline: Date, now: Date) -> Bool {
        deadline < now
    }

    // MARK: - Subtask tree helpers (issue #17, PRD §5.4/§20.2)

    /// The total number of descendants of `subtask` — children, grandchildren,
    /// … at any depth (unbounded nesting). The pure core of the #17 delete
    /// confirmation: when N > 0 the dialog says "… and its N subtasks". The
    /// subtask itself is not counted.
    public static func descendantCount(of subtask: SubtaskItem) -> Int {
        subtask.children.reduce(subtask.children.count) {
            $0 + descendantCount(of: $1)
        }
    }

    /// The persistent collapse key for a task row's subtask-tree disclosure
    /// (issue #17). ID-based — stable across relaunches and title edits.
    public static func taskCollapseKey(_ taskID: UUID) -> String {
        "task:\(taskID.uuidString)"
    }

    /// The persistent collapse key for one subtask node's disclosure, scoped
    /// by its top-level task so the same subtask ID in different files (or a
    /// coincidental UUID reuse) never shares collapse state.
    public static func subtaskCollapseKey(taskID: UUID, subtaskID: UUID) -> String {
        "\(taskCollapseKey(taskID))|subtask:\(subtaskID.uuidString)"
    }

    // MARK: - Collapse keys (stable across relaunches)

    /// The persistent collapse key for a project section. `nil` project (No
    /// Project) uses a `<none>` sentinel; a vault project literally named
    /// `<none>` would share its collapse state with the No Project section —
    /// cosmetic, accepted (the key only drives expand/collapse memory).
    public static func projectCollapseKey(_ project: Project?) -> String {
        project.map { "project:\($0.name)" } ?? "project:<none>"
    }

    /// The persistent collapse key for a status sub-group, scoped by its
    /// project section so identical statuses in different projects collapse
    /// independently.
    public static func statusCollapseKey(project: Project?, status: TaskStatus) -> String {
        "\(projectCollapseKey(project))|status:\(status.rawValue)"
    }
}

/// One project (or the No Project) section of the Tasks view — a node in
/// `TasksGrouping.sections`' output. `Identifiable`/`Equatable` for SwiftUI
/// and tests.
public struct TaskSection: Identifiable, Equatable, Sendable {
    /// The section's project, or `nil` for the pinned-bottom No Project
    /// section.
    public let project: Project?
    /// The status sub-groups in the pinned order (see `TasksGrouping`).
    public let groups: [TaskStatusGroup]
    /// The persistent collapse key (backed by `UserDefaults`).
    public let collapseKey: String

    public var id: String { collapseKey }
    /// Whether this is the No Project section.
    public var isNoProject: Bool { project == nil }
    /// The header label: the project name, or `No Project`.
    public var displayName: String { project?.name ?? "No Project" }
    /// Total eligible tasks across all status groups (header count).
    public var totalCount: Int {
        groups.reduce(0) { $0 + $1.tasks.count }
    }
}

/// One status sub-group inside a `TaskSection`: the tasks in #10 display
/// order plus the persistent collapse key.
public struct TaskStatusGroup: Identifiable, Equatable, Sendable {
    public let status: TaskStatus
    /// The group's tasks, ordered by the #10 display-order rule.
    public let tasks: [TaskItem]
    /// The persistent collapse key (backed by `UserDefaults`).
    public let collapseKey: String

    public var id: String { collapseKey }
}
