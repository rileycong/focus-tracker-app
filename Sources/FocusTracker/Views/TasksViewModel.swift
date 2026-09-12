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
        }
    }

    /// The single selected task (visual only, #15; consumed by #16/#19).
    /// `nil` = nothing selected. Tapping a selected row deselects it.
    public var selectedTaskID: UUID?

    /// The latest task snapshot (mirrors `AppModel.tasks`).
    private var tasks: [TaskItem] = []
    /// The injected collapsible-state store.
    private let collapseStore: any CollapseStateStoring

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
    /// view whenever `AppModel.tasks` changes (load, vault switch, …).
    public func updateTasks(_ tasks: [TaskItem]) {
        self.tasks = tasks
        rebuildSections()
    }

    private func rebuildSections() {
        sections = TasksGrouping.sections(tasks: tasks, showCompleted: showCompleted)
    }

    // MARK: - Collapsible state (persisted via the injected store)

    /// Whether the section with `key` is expanded (never-touched keys start
    /// expanded; values persist across relaunches).
    public func isExpanded(forKey key: String) -> Bool {
        collapseStore.isExpanded(forKey: key)
    }

    /// Persists the expanded state for the section with `key`.
    public func setExpanded(_ expanded: Bool, forKey key: String) {
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
}
