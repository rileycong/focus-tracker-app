import Foundation
import Observation
import SwiftUI

/// The observable view model of the Tasks view (issue #15): wraps the pure
/// `TasksGrouping` logic with the two pieces of *state* the view needs —
/// the Done/Dropped filter toggle and single task selection (visual only for
/// now; #16 edit and #19 start flows consume it later) — and persists
/// collapsible section state through the injected `CollapseStateStoring`
/// (a `UserDefaults`-backed store in production; an isolated suite in tests).
///
/// Deliberately **decoupled from `AppModel`**: the view model holds a snapshot
/// of `[TaskItem]` that the view keeps in step via `updateTasks(_:)`
/// (`.onChange` of `AppModel.tasks`), so the grouping logic is unit-testable
/// without any vault, and the model stays exactly the #14 composition root.
///
/// Section structure is *derived*, never stored: `sections` is recomputed
/// from `tasks + showCompleted` on every change (pure function → no drift).
///
/// # Expansion state is observable-tracked (issue #32)
/// Toggling a section reads and writes the injected store, which is plain
/// `UserDefaults` — nothing SwiftUI can observe. Before #32 the views bound
/// to the store *directly*, so a toggle persisted the new value but changed
/// no tracked state: the DisclosureGroups and row chevrons never re-rendered
/// and appeared dead ("sections can't be collapsed/opened") until some
/// unrelated change happened to redraw the list. The fix: the view model
/// mirrors the store in the tracked `expansionCache` — reads hit the cache
/// (an observable read, so the view registers a dependency), writes go to
/// the cache *and* through to the store (persistence contract unchanged:
/// relaunches still resolve from `UserDefaults`). The cache is re-seeded for
/// every key the current structure renders on each `updateTasks(_:)`, so a
/// changed inventory (completion, deletion, reorder, vault switch) can never
/// leave the toggles stuck on stale state — vanished keys simply stop being
/// queried, surviving keys resolve from the store they were persisted to.
///
/// # Done/Dropped auto-reveal on change (issue #32, PRD §8.3)
/// When an inventory change moves a top-level task into Done or Dropped
/// (e.g. its last subtask was completed at the end of a session), the whole
/// tree leaves the active groups. With the filter ON those groups are
/// rendered but may sit collapsed — so `updateTasks(_:)` auto-expands the
/// receiving section + status group (see `autoExpandKeys(from:to:)`); with
/// the filter OFF the groups are not rendered at all (pinned §8.3 rule) and
/// discoverability is the `AppModel.completionNotice` transient banner +
/// the empty-state's "Show completed/dropped" action instead.
@MainActor
@Observable
public final class TasksViewModel {

    /// The current section structure — projects sorted by name, No Project
    /// last, status sub-groups per the pinned rules (see `TasksGrouping`).
    public private(set) var sections: [TaskSection] = []

    /// The Done/Dropped filter (PRD §8.3: hidden by default). Toggling
    /// recomputes `sections`.
    public var showCompleted: Bool {
        didSet {
            guard oldValue != showCompleted else { return }
            rebuildSections()
            refreshExpansionCache()
        }
    }

    /// The single selected task (visual only, #15; consumed by #16/#19).
    /// `nil` = nothing selected. Tapping a selected row deselects it.
    public var selectedTaskID: UUID?

    /// The latest task snapshot (mirrors `AppModel.tasks`).
    private var tasks: [TaskItem] = []
    /// The injected collapsible-state store.
    private let collapseStore: any CollapseStateStoring
    /// The tracked expansion mirror (see the type documentation): every key
    /// the current structure renders → whether it is expanded. Written only
    /// here in the model, always in step with the store.
    private var expansionCache: [String: Bool] = [:]

    /// - Parameters:
    ///   - tasks: The initial task snapshot (filename-sorted inventory order).
    ///   - showCompleted: Initial filter state (production default: off, per
    ///     PRD §8.3 "hidden by default").
    ///   - collapseStore: The injected persistence for expand/collapse state.
    public init(
        tasks: [TaskItem] = [],
        showCompleted: Bool = false,
        collapseStore: any CollapseStateStoring
    ) {
        self.collapseStore = collapseStore
        self.showCompleted = showCompleted
        updateTasks(tasks)
    }

    /// Replaces the task snapshot and recomputes `sections`. Called by the
    /// view whenever `AppModel.tasks` changes (load, vault switch, …). Also
    /// re-seeds the expansion cache from the store for every key the new
    /// structure renders (never stuck on stale keys), and auto-expands the
    /// Done/Dropped groups that received tasks while the filter is on.
    public func updateTasks(_ tasks: [TaskItem]) {
        let previous = self.tasks
        self.tasks = tasks
        rebuildSections()
        refreshExpansionCache()
        if showCompleted {
            for key in Self.autoExpandKeys(from: previous, to: tasks) {
                setExpanded(true, forKey: key)
            }
        }
    }

    private func rebuildSections() {
        sections = TasksGrouping.sections(tasks: tasks, showCompleted: showCompleted)
    }

    /// Re-seeds `expansionCache` from the store for every key the current
    /// structure renders (section + status-group keys, and every task/subtask
    /// row's disclosure key). Store-backed values always win — the store is
    /// exactly where this model persisted every toggle — so this can never
    /// override a fresher value; keys the structure no longer renders drop
    /// out of the cache (harmless leftovers in the store stay there).
    private func refreshExpansionCache() {
        var resolved: [String: Bool] = [:]
        func seed(_ key: String) {
            resolved[key] = collapseStore.isExpanded(forKey: key)
        }
        for section in sections {
            seed(section.collapseKey)
            for group in section.groups {
                seed(group.collapseKey)
            }
        }
        for task in tasks {
            seed(TasksGrouping.taskCollapseKey(task.id))
            seedSubtaskKeys(taskID: task.id, task.subtasks, into: &resolved)
        }
        expansionCache = resolved
    }

    private func seedSubtaskKeys(
        taskID: UUID, _ subtasks: [SubtaskItem], into resolved: inout [String: Bool]
    ) {
        for subtask in subtasks {
            resolved[
                TasksGrouping.subtaskCollapseKey(taskID: taskID, subtaskID: subtask.id)
            ] = collapseStore.isExpanded(
                forKey: TasksGrouping.subtaskCollapseKey(taskID: taskID, subtaskID: subtask.id))
            seedSubtaskKeys(taskID: taskID, subtask.children, into: &resolved)
        }
    }

    /// The collapse keys to auto-expand because an inventory change moved a
    /// top-level task from an active status into Done/Dropped (issue #32):
    /// for each moved task, its project section key + status group key, in
    /// the task's inventory order, deduplicated. Tasks that were already
    /// Done/Dropped before (or appear new with those statuses, e.g. the
    /// first load or a vault switch) never match — this reveals *transitions*,
    /// so persisted collapsed state survives relaunches and unrelated
    /// inventory churn.
    static func autoExpandKeys(
        from previous: [TaskItem], to current: [TaskItem]
    ) -> [String] {
        let previousStatuses = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.id, $0.status) })
        var keys: [String] = []
        var seen: Set<String> = []
        for task in current where task.status == .done || task.status == .dropped {
            guard let oldStatus = previousStatuses[task.id],
                oldStatus != .done, oldStatus != .dropped, oldStatus != task.status
            else { continue }
            for key in [
                TasksGrouping.projectCollapseKey(task.project),
                TasksGrouping.statusCollapseKey(
                    project: task.project, status: task.status),
            ] where seen.insert(key).inserted {
                keys.append(key)
            }
        }
        return keys
    }

    // MARK: - Collapsible state (persisted via the injected store)

    /// Whether the section with `key` is expanded (never-touched keys start
    /// expanded; values persist across relaunches). Reads the tracked cache —
    /// the observable dependency that makes toggles re-render (issue #32);
    /// a key outside the current structure resolves straight from the store.
    public func isExpanded(forKey key: String) -> Bool {
        if let cached = expansionCache[key] { return cached }
        return collapseStore.isExpanded(forKey: key)
    }

    /// Persists the expanded state for the section with `key`: into the
    /// tracked cache (the immediate re-render) and through to the store
    /// (the relaunch path).
    public func setExpanded(_ expanded: Bool, forKey key: String) {
        expansionCache[key] = expanded
        collapseStore.setExpanded(expanded, forKey: key)
    }

    /// Flips the persisted expanded state for the section with `key`.
    public func toggleExpanded(forKey key: String) {
        setExpanded(!isExpanded(forKey: key), forKey: key)
    }

    /// A `Binding<Boolean>`-shaped pair for the section with `key`, for
    /// SwiftUI `DisclosureGroup(isExpanded:)`.
    public func expandedBinding(forKey key: String) -> Binding<Bool> {
        Binding(
            get: { self.isExpanded(forKey: key) },
            set: { self.setExpanded($0, forKey: key) })
    }

    // MARK: - Selection (visual only, #15)

    /// Selects the task with `id`, or deselects when tapping it again.
    public func toggleSelection(of id: UUID) {
        selectedTaskID = selectedTaskID == id ? nil : id
    }

    /// Whether the task with `id` is currently selected (row highlight).
    public func isSelected(_ id: UUID) -> Bool {
        selectedTaskID == id
    }

    /// The (project, status) group containing the task with `id` — the scope
    /// the #18 keyboard reorder (⌘⇧↑ / ⌘⇧↓ on the selected task) derives its
    /// swap from. Derived from `sections`, so it reflects the exact groups the
    /// view renders (Done/Dropped filter applied). nil = not displayed.
    public func group(containing id: UUID) -> TaskStatusGroup? {
        for section in sections {
            for group in section.groups where group.tasks.contains(where: { $0.id == id }) {
                return group
            }
        }
        return nil
    }
}
