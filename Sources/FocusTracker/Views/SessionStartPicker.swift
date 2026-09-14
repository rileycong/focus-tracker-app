import Foundation

/// One selectable session-start target in the `SessionStartView` picker
/// (issue #19, PRD §9.1): a top-level task or a subtask at any depth,
/// flattened out of the `[TaskItem]` inventory with everything the start
/// flow and the picker row need. Pure value — no SwiftUI, no I/O — so the
/// picker's eligibility/grouping logic is unit-testable like
/// `TasksGrouping` (#15).
public struct SessionStartTarget: Identifiable, Equatable, Sendable {

    /// The target's own stable ID — the one ID the whole start flow
    /// addresses (`VaultStore.lookup` #6, `VaultStore.startSession` #9, the
    /// engine #12) and the picker selection carries.
    public let id: UUID
    /// The top-level task whose file owns the target (its own ID when the
    /// target is a task).
    public let parentTaskID: UUID
    /// The target's own title.
    public let title: String
    /// The target's own status — the sole eligibility input (#9's
    /// planning-eligible state rule is per-node; see `SessionStartPicker`).
    public let status: TaskStatus
    /// The effective project (PRD §5.4: subtasks inherit from the parent
    /// task; a task carries its own). Drives the section grouping.
    public let project: Project?
    /// The effective categories (PRD §5.4 inheritance) — display metadata.
    public let categories: [Category]
    /// Titles from the owning task down to and including the target:
    /// `[task.title]` for a task target, one level deeper per subtask
    /// ancestor. `depth ≥ 1` is exactly `count ≥ 2` (the #19 subtask-target
    /// criterion).
    public let path: [String]

    /// Nesting depth: 0 for a top-level task, 1+ for subtasks.
    public var depth: Int { path.count - 1 }
    /// Whether the target is a top-level task (vs a subtask at any depth).
    public var isTask: Bool { depth == 0 }
    /// The owning task's title (`path[0]`) — shown as the subtask row's
    /// context line in the picker.
    public var parentTaskTitle: String { path[0] }
}

/// One status sub-group of the picker (issue #19: "grouped like the tasks
/// view"). `Identifiable`/`Equatable` for SwiftUI lists and tests.
public struct SessionStartGroup: Identifiable, Equatable, Sendable {
    public let status: TaskStatus
    /// The group's eligible targets, in inventory/tree order (documented on
    /// `SessionStartPicker.sections(from:)`).
    public let targets: [SessionStartTarget]

    public var id: TaskStatus { status }
}

/// One project (or the No Project) section of the picker.
public struct SessionStartSection: Identifiable, Equatable, Sendable {
    /// The section's project, or nil for the pinned-bottom No Project
    /// section — the same shape as the #15 `TaskSection`.
    public let project: Project?
    /// The non-empty status sub-groups, in the pinned order.
    public let groups: [SessionStartGroup]

    public var displayName: String { project?.name ?? "No Project" }
    public var id: String { project?.name ?? "<none>" }
    /// Total eligible targets across all status groups (header count).
    public var totalCount: Int {
        groups.reduce(0) { $0 + $1.targets.count }
    }
}

/// The pure session-start picker core (issue #19, PRD §8.6, §9.1): the
/// `[TaskItem]` inventory in filename-sorted order → the eligible targets
/// (task or subtask, any depth) grouped like the tasks view. No UI, no
/// state, no I/O — deliberately derived from the plain inventory, **not**
/// from the mutable `TasksViewModel` (the #19 criterion pins this), so it
/// cannot drift with the tasks view's Done/Dropped filter or collapse state.
///
/// **Eligibility (pinned, #9):** a node is eligible exactly when its own
/// status is `To Do` or `In Progress` — `StatusTransition
/// .isPlanningEligible` reused verbatim, which encodes NOT `Blocked`, NOT
/// `Dropped`, and `Done` excluded (the #9 `startSession` refusals
/// `.blocked`/`.dropped`/`.alreadyDone` would refuse the other three).
/// Exclusion is by the node's own status only: whether an ineligible
/// ancestor hides its descendants is a Lifebot filtering decision, pinned
/// out of scope on `StatusTransition.planningEligibleIDs(in:)` — the picker
/// follows the same rule (in a well-formed vault a Done parent's children
/// are all Done anyway, because #3's completion bubbles up).
///
/// **Grouping (pinned shape, #19):** project sections sorted by name with
/// No Project pinned last, and status sub-groups in the pinned order To Do →
/// In Progress (the pinned tasks-view order's eligible subset). Documented
/// choice: only **non-empty** status groups appear — the tasks view always
/// renders its three active groups because it is an inventory browser, while
/// the picker is a choice list where an empty group offers nothing to
/// select. Documented choice: within a group, targets keep the
/// inventory/tree order of `eligibleTargets(in:)` (filename-sorted tasks,
/// depth-first subtasks under their parent) — the #10 manual display-order
/// rule is an inventory-browser affordance the picker does not need, and
/// the criterion pins the *grouping*, not a within-group ordering.
///
/// **Search (cheap, #19 "if cheap"):** a case-insensitive substring match
/// over the target's own title and its owning task's title — enough to find
/// a nested subtask without any index structure.
public enum SessionStartPicker {

    /// The eligible statuses, in the pinned sub-group display order (the
    /// tasks-view pinned order's eligible subset).
    public static let eligibleStatuses: [TaskStatus] = [.toDo, .inProgress]

    /// Whether a node in this status may start a session (#9: the
    /// planning-eligible state rule, reused verbatim).
    public static func isEligible(_ status: TaskStatus) -> Bool {
        status.isPlanningEligible
    }

    /// Flattens every eligible target out of the inventory, in
    /// inventory/tree order: tasks in filename-sorted order, each followed
    /// by its eligible subtasks depth-first (a subtask inherits the parent
    /// task's project/categories per PRD §5.4).
    public static func eligibleTargets(in tasks: [TaskItem]) -> [SessionStartTarget] {
        var targets: [SessionStartTarget] = []
        for task in tasks {
            if isEligible(task.status) {
                targets.append(
                    SessionStartTarget(
                        id: task.id, parentTaskID: task.id, title: task.title,
                        status: task.status, project: task.project,
                        categories: task.categories, path: [task.title]))
            }
            collectEligible(
                in: task.subtasks, parentTask: task, path: [task.title],
                into: &targets)
        }
        return targets
    }

    /// Builds the grouped picker structure from a target list (see the
    /// grouping rules on the type). Pass `eligibleTargets(in:)` output for
    /// the unfiltered picker; pass a filtered list for the search field.
    public static func sections(from targets: [SessionStartTarget]) -> [SessionStartSection] {
        guard !targets.isEmpty else { return [] }
        let projects = Set(targets.compactMap(\.project)).sorted { $0.name < $1.name }
        var sections = projects.map { project in
            SessionStartSection(
                project: project, groups: statusGroups(for: project, in: targets))
        }
        if targets.contains(where: { $0.project == nil }) {
            sections.append(
                SessionStartSection(
                    project: nil, groups: statusGroups(for: nil, in: targets)))
        }
        return sections
    }

    /// The one-call picker entry: eligible targets of `tasks`, optionally
    /// filtered by the search query, grouped per the pinned rules.
    public static func sections(
        in tasks: [TaskItem], matching query: String = ""
    ) -> [SessionStartSection] {
        let filtered = eligibleTargets(in: tasks).filter { matches($0, query: query) }
        return sections(from: filtered)
    }

    /// The search rule: case-insensitive substring over the target's own
    /// title **or** the owning task's title (so "roadmap" finds its nested
    /// subtasks too). An empty/whitespace query matches everything.
    public static func matches(_ target: SessionStartTarget, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return target.title.localizedCaseInsensitiveContains(trimmed)
            || target.parentTaskTitle.localizedCaseInsensitiveContains(trimmed)
    }

    // MARK: - Pre-selection (issue #34)

    /// The effective picker pre-selection (issue #34): `requestedID` when
    /// it is planning-eligible in the given inventory, else nil. The
    /// session-start sheet applies it on appear, so a Done, Blocked or
    /// Dropped previous task — or an ID no longer in the inventory —
    /// simply leaves the picker unselected (the current #19 behavior).
    /// Pure so the eligibility rule is unit-testable like the grouping
    /// (#19) and its callers (the sheet and the tests) cannot drift.
    public static func preselectedTargetID(
        requesting requestedID: UUID?, in tasks: [TaskItem]
    ) -> UUID? {
        guard let requestedID,
            eligibleTargets(in: tasks).contains(where: { $0.id == requestedID })
        else { return nil }
        return requestedID
    }


    // MARK: - Internals

    /// Depth-first walk of one sibling list; `path` is the title chain from
    /// the owning task down to (not including) the candidate.
    private static func collectEligible(
        in subtasks: [SubtaskItem], parentTask: TaskItem, path: [String],
        into targets: inout [SessionStartTarget]
    ) {
        for subtask in subtasks {
            let targetPath = path + [subtask.title]
            if isEligible(subtask.status) {
                targets.append(
                    SessionStartTarget(
                        id: subtask.id, parentTaskID: parentTask.id,
                        title: subtask.title, status: subtask.status,
                        project: parentTask.project,
                        categories: parentTask.categories, path: targetPath))
            }
            collectEligible(
                in: subtask.children, parentTask: parentTask, path: targetPath,
                into: &targets)
        }
    }

    /// The non-empty status groups of one project section, pinned order.
    private static func statusGroups(
        for project: Project?, in targets: [SessionStartTarget]
    ) -> [SessionStartGroup] {
        eligibleStatuses.compactMap { status in
            let groupTargets = targets.filter {
                $0.project == project && $0.status == status
            }
            return groupTargets.isEmpty
                ? nil
                : SessionStartGroup(status: status, targets: groupTargets)
        }
    }
}
