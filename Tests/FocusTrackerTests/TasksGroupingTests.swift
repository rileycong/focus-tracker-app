import XCTest
@testable import FocusTracker

/// Tests for the #15 Tasks view's pure view-model logic: the
/// `TasksGrouping.sections` grouping/ordering rules (project grouping +
/// name sorting, No Project pinned last, status sub-groups with the
/// Done/Dropped filter, the #10 `TaskOrdering.displayOrder` rule within
/// groups), the overdue determination, the collapsible-state persistence
/// round-trip through an injected `UserDefaults`-backed store, and the
/// `TasksViewModel` recompute/selection behavior.
///
/// Conventions follow the #10/#14 tests: unique IDs per fixture, isolated
/// `UserDefaults` suites (removed in teardown), no disk I/O beyond that.
final class TasksGroupingTests: XCTestCase {

    // MARK: - Fixtures

    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()
    private static let d = UUID()
    private static let e = UUID()
    private static let f = UUID()

    private static let work = Project(name: "Work")
    private static let home = Project(name: "Home")
    private static let zeta = Project(name: "Zeta")

    /// Inventory-order helper: the input list is the filename-sorted order
    /// the vault provides, so the array position is the #10 tie-break.
    private func task(
        _ id: UUID,
        title: String? = nil,
        project: Project? = nil,
        status: TaskStatus = .toDo,
        order: Int? = nil,
        deadline: Date? = nil,
        priority: Priority? = nil,
        effort: Effort? = nil,
        subtaskCount: Int = 0
    ) -> TaskItem {
        // Categories are non-empty, so the throwing initializer cannot fail.
        try! TaskItem(
            id: id,
            title: title ?? id.uuidString,
            categories: [Category(name: "C")],
            status: status,
            project: project,
            priority: priority,
            effort: effort,
            deadline: deadline,
            order: order,
            subtasks: (0..<subtaskCount).map { SubtaskItem(title: "s\($0)") })
    }

    /// All task titles across the structure, for content assertions.
    private func taskIDs(in sections: [TaskSection]) -> [UUID] {
        sections.flatMap { section in
            section.groups.flatMap(\.tasks).map(\.id)
        }
    }

    // MARK: - Project grouping, sorting, No Project last

    func testEmptyTaskListYieldsNoSections() {
        XCTAssertEqual(TasksGrouping.sections(tasks: [], showCompleted: false), [])
        XCTAssertEqual(TasksGrouping.sections(tasks: [], showCompleted: true), [])
    }

    func testProjectSectionsSortedByName() {
        let sections = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: Self.zeta),
                task(Self.b, project: Self.work),
                task(Self.c, project: Self.home),
            ],
            showCompleted: false)
        XCTAssertEqual(sections.map(\.displayName), ["Home", "Work", "Zeta"])
    }

    func testNoProjectSectionPinnedLast() {
        let sections = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: nil),
                task(Self.b, project: Self.work),
                task(Self.c, project: Self.home),
            ],
            showCompleted: false)
        XCTAssertEqual(sections.map(\.displayName), ["Home", "Work", "No Project"])
        XCTAssertTrue(sections.last!.isNoProject)
        XCTAssertNil(sections.last!.project)
    }

    func testNoProjectSectionAbsentWhenEveryTaskHasAProject() {
        let sections = TasksGrouping.sections(
            tasks: [task(Self.a, project: Self.work), task(Self.b, project: Self.work)],
            showCompleted: true)
        XCTAssertEqual(sections.map(\.displayName), ["Work"])
        XCTAssertFalse(sections[0].isNoProject)
    }

    // MARK: - Status sub-groups (always-on actives, filter on/off)

    func testActiveStatusGroupsAlwaysPresentInPinnedOrderEvenWhenEmpty() {
        let sections = TasksGrouping.sections(tasks: [task(Self.a)], showCompleted: false)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(
            sections[0].groups.map(\.status),
            [.toDo, .inProgress, .blocked],
            "the three active groups are always present, in the pinned order")
        XCTAssertEqual(sections[0].groups[0].tasks.map(\.id), [Self.a])
        XCTAssertTrue(sections[0].groups[1].tasks.isEmpty, "In Progress empty")
        XCTAssertTrue(sections[0].groups[2].tasks.isEmpty, "Blocked empty")
    }

    func testDoneAndDroppedHiddenByDefaultAndExcludedFromGrouping() {
        let sections = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: Self.work, status: .toDo),
                task(Self.b, project: Self.work, status: .done),
                task(Self.c, project: Self.work, status: .dropped),
            ],
            showCompleted: false)
        XCTAssertEqual(
            sections[0].groups.map(\.status),
            [.toDo, .inProgress, .blocked],
            "Done/Dropped groups never appear with the filter off")
        XCTAssertEqual(taskIDs(in: sections), [Self.a], "Done/Dropped tasks excluded")
    }

    func testDoneOnlyProjectYieldsNoSectionWhileFilterOff() {
        let sections = TasksGrouping.sections(
            tasks: [task(Self.a, project: Self.work, status: .done), task(Self.b)],
            showCompleted: false)
        XCTAssertEqual(sections.map(\.displayName), ["No Project"])
    }

    func testFilterOnShowsDoneAndDroppedGroupsInPinnedOrder() {
        let sections = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: Self.work, status: .toDo),
                task(Self.b, project: Self.work, status: .done),
                task(Self.c, project: Self.work, status: .dropped),
            ],
            showCompleted: true)
        XCTAssertEqual(
            sections[0].groups.map(\.status),
            [.toDo, .inProgress, .blocked, .done, .dropped],
            "Done/Dropped are appended in the pinned order")
        XCTAssertEqual(sections[0].groups[3].tasks.map(\.id), [Self.b])
        XCTAssertEqual(sections[0].groups[4].tasks.map(\.id), [Self.c])
    }

    func testFilterOnRevealsDoneOnlyProject() {
        let sections = TasksGrouping.sections(
            tasks: [task(Self.a, project: Self.work, status: .done), task(Self.b)],
            showCompleted: true)
        XCTAssertEqual(sections.map(\.displayName), ["Work", "No Project"])
        XCTAssertEqual(sections[0].groups[3].tasks.map(\.id), [Self.a])
    }

    func testNoProjectSectionAlsoAbsentWhenOnlyCompletedUnprojectedTasksAndFilterOff() {
        let sections = TasksGrouping.sections(
            tasks: [task(Self.a, status: .done)], showCompleted: false)
        XCTAssertEqual(sections, [], "nothing eligible → no sections at all")
    }

    // MARK: - #10 display order within groups

    func testDisplayOrderOrderedFirstAscendingUnorderedLastInInventoryOrder() {
        // Inventory order: a(order 2), b(nil), c(order 0), d(order 1), e(nil)
        // — one (project, status) group. Expected: ordered 0,1,2 first, then
        // the unordered tasks in inventory order (b before e).
        let sections = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: Self.work, order: 2),
                task(Self.b, project: Self.work),
                task(Self.c, project: Self.work, order: 0),
                task(Self.d, project: Self.work, order: 1),
                task(Self.e, project: Self.work),
            ],
            showCompleted: false)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(
            sections[0].groups[0].tasks.map(\.id),
            [Self.c, Self.d, Self.a, Self.b, Self.e])
    }

    func testDisplayOrderTieBreaksByInventoryPosition() {
        // Equal `order` values tie-break by filename-sorted inventory
        // position: `a` is passed first (position 0), so it displays first.
        let sections = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: Self.work, order: 1),
                task(Self.b, project: Self.work, order: 1),
            ],
            showCompleted: false)
        XCTAssertEqual(sections[0].groups[0].tasks.map(\.id), [Self.a, Self.b])
    }

    func testDisplayOrderIsScopedToEachProjectStatusGroup() {
        // Same order values across groups must order independently within
        // each (project, status) group — the #10 group scoping.
        let sections = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: Self.work, status: .toDo, order: 1),
                task(Self.b, project: Self.work, status: .toDo, order: 0),
                task(Self.c, project: Self.home, status: .toDo, order: 1),
                task(Self.d, project: Self.home, status: .toDo, order: 0),
                task(Self.e, project: Self.work, status: .inProgress, order: 1),
                task(Self.f, project: Self.work, status: .inProgress, order: 0),
            ],
            showCompleted: false)
        let work = sections.first { $0.displayName == "Work" }!
        let home = sections.first { $0.displayName == "Home" }!
        XCTAssertEqual(work.groups[0].tasks.map(\.id), [Self.b, Self.a])
        XCTAssertEqual(work.groups[1].tasks.map(\.id), [Self.f, Self.e])
        XCTAssertEqual(home.groups[0].tasks.map(\.id), [Self.d, Self.c])
    }

    func testGroupingMatchesTaskOrderingDisplayOrderDirectly() {
        let tasks = [
            task(Self.a, project: Self.work, status: .inProgress, order: 5),
            task(Self.b, project: Self.work, status: .inProgress),
            task(Self.c, project: Self.work, status: .inProgress, order: 2),
            task(Self.d, project: Self.work, status: .inProgress, order: 2),
        ]
        let sections = TasksGrouping.sections(tasks: tasks, showCompleted: false)
        let expected = TaskOrdering.displayOrder(of: tasks)[
            TaskOrdering.Group(project: Self.work, status: .inProgress)]!
        XCTAssertEqual(sections[0].groups[1].tasks.map(\.id), expected)
    }

    // MARK: - Section shape helpers

    func testSectionCountsAndCollapseKeysAreDerivedAndStable() {
        let sections = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: Self.work, status: .toDo),
                task(Self.b, project: Self.work, status: .inProgress),
                task(Self.c),
            ],
            showCompleted: false)
        XCTAssertEqual(sections[0].totalCount, 2)
        XCTAssertEqual(sections[0].collapseKey, TasksGrouping.projectCollapseKey(Self.work))
        XCTAssertEqual(
            sections[0].groups[0].collapseKey,
            TasksGrouping.statusCollapseKey(project: Self.work, status: .toDo))
        XCTAssertEqual(
            sections[1].collapseKey, TasksGrouping.projectCollapseKey(nil),
            "the No Project key differs from every named-project key")
        // Deterministic: same input → identical structure.
        let again = TasksGrouping.sections(
            tasks: [
                task(Self.a, project: Self.work, status: .toDo),
                task(Self.b, project: Self.work, status: .inProgress),
                task(Self.c),
            ],
            showCompleted: false)
        XCTAssertEqual(sections, again)
    }

    // MARK: - Overdue determination

    func testOverdueDetermination() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(
            TasksGrouping.isOverdue(
                deadline: now.addingTimeInterval(-1), now: now),
            "a past deadline is overdue")
        XCTAssertFalse(
            TasksGrouping.isOverdue(
                deadline: now.addingTimeInterval(60), now: now),
            "a future deadline is not overdue")
        XCTAssertFalse(
            TasksGrouping.isOverdue(deadline: now, now: now),
            "a deadline exactly at now is due-now, not overdue")
    }

    // MARK: - Collapsible persistence (injected defaults, relaunch path)

    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "TasksGroupingTests-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testCollapseStoreDefaultsToExpandedForNeverStoredKeys() {
        let store = UserDefaultsCollapseStateStore(
            defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertTrue(store.isExpanded(forKey: "project:Work"))
    }

    @MainActor
    func testCollapseStoreRoundTripsAcrossInstancesLikeARelaunch() {
        let store = UserDefaultsCollapseStateStore(
            defaults: UserDefaults(suiteName: suiteName)!)
        store.setExpanded(false, forKey: "project:Work")
        store.setExpanded(true, forKey: "project:Home")
        store.setExpanded(false, forKey: "project:<none>")

        // A NEW store over the SAME suite — the app-relaunch path.
        let reloaded = UserDefaultsCollapseStateStore(
            defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertFalse(reloaded.isExpanded(forKey: "project:Work"))
        XCTAssertTrue(reloaded.isExpanded(forKey: "project:Home"))
        XCTAssertFalse(reloaded.isExpanded(forKey: "project:<none>"))
        XCTAssertTrue(
            reloaded.isExpanded(forKey: "project:Untouched"),
            "keys never written still default to expanded")
    }

    @MainActor
    func testCollapseStoreExplicitTrueRoundTripsAndDoesNotReadAsAbsent() {
        let store = UserDefaultsCollapseStateStore(
            defaults: UserDefaults(suiteName: suiteName)!)
        store.setExpanded(true, forKey: "project:Work")
        let reloaded = UserDefaultsCollapseStateStore(
            defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertTrue(reloaded.isExpanded(forKey: "project:Work"))
    }

    // MARK: - TasksViewModel (recompute, persistence, selection)

    @MainActor
    func testViewModelRecomputesSectionsOnTaskUpdate() {
        let viewModel = TasksViewModel(
            collapseStore: UserDefaultsCollapseStateStore(
                defaults: UserDefaults(suiteName: suiteName)!))
        XCTAssertTrue(viewModel.sections.isEmpty)

        viewModel.updateTasks([
            task(Self.a, project: Self.work),
            task(Self.b, project: Self.work, status: .done),
        ])
        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(taskIDs(in: viewModel.sections), [Self.a])

        viewModel.updateTasks([])
        XCTAssertTrue(viewModel.sections.isEmpty)
    }

    @MainActor
    func testViewModelShowCompletedToggleRecomputesSections() {
        let viewModel = TasksViewModel(
            tasks: [task(Self.a, project: Self.work, status: .done)],
            collapseStore: UserDefaultsCollapseStateStore(
                defaults: UserDefaults(suiteName: suiteName)!))
        XCTAssertFalse(viewModel.showCompleted)
        XCTAssertTrue(viewModel.sections.isEmpty, "done-only vault is hidden by default")

        viewModel.showCompleted = true
        XCTAssertEqual(viewModel.sections.map(\.displayName), ["Work"])
        XCTAssertEqual(taskIDs(in: viewModel.sections), [Self.a])

        viewModel.showCompleted = false
        XCTAssertTrue(viewModel.sections.isEmpty)
    }

    @MainActor
    func testViewModelCollapseStatePersistsThroughInjectedDefaults() {
        let workKey = TasksGrouping.projectCollapseKey(Self.work)
        let viewModel = TasksViewModel(
            tasks: [task(Self.a, project: Self.work)],
            collapseStore: UserDefaultsCollapseStateStore(
                defaults: UserDefaults(suiteName: suiteName)!))
        XCTAssertTrue(viewModel.isExpanded(forKey: workKey))
        viewModel.setExpanded(false, forKey: workKey)
        XCTAssertFalse(viewModel.isExpanded(forKey: workKey))

        // A fresh view model over the SAME suite — the relaunch path.
        let relaunched = TasksViewModel(
            tasks: [task(Self.a, project: Self.work)],
            collapseStore: UserDefaultsCollapseStateStore(
                defaults: UserDefaults(suiteName: suiteName)!))
        XCTAssertFalse(
            relaunched.isExpanded(forKey: workKey),
            "collapsed state survives a relaunch via the injected store")
        XCTAssertTrue(
            relaunched.isExpanded(
                forKey: TasksGrouping.statusCollapseKey(project: Self.work, status: .toDo)),
            "untouched status groups still default to expanded")
    }

    @MainActor
    func testViewModelSelectionIsSingleAndTogglesOff() {
        let viewModel = TasksViewModel(
            tasks: [task(Self.a), task(Self.b)],
            collapseStore: UserDefaultsCollapseStateStore(
                defaults: UserDefaults(suiteName: suiteName)!))
        XCTAssertNil(viewModel.selectedTaskID)

        viewModel.toggleSelection(of: Self.a)
        XCTAssertTrue(viewModel.isSelected(Self.a))
        XCTAssertFalse(viewModel.isSelected(Self.b))

        viewModel.toggleSelection(of: Self.b)
        XCTAssertEqual(
            viewModel.selectedTaskID, Self.b,
            "selection is single — the new tap replaces the old")
        XCTAssertFalse(viewModel.isSelected(Self.a))

        viewModel.toggleSelection(of: Self.b)
        XCTAssertNil(viewModel.selectedTaskID, "tapping the selection deselects")
    }

    @MainActor
    func testViewModelExpandedBindingWritesThroughToTheStore() {
        let key = TasksGrouping.projectCollapseKey(Self.work)
        let suite = UserDefaults(suiteName: suiteName)!
        let viewModel = TasksViewModel(
            collapseStore: UserDefaultsCollapseStateStore(defaults: suite))
        let binding = viewModel.expandedBinding(forKey: key)
        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertFalse(binding.wrappedValue)
        // And through a second view model over the same suite:
        let other = TasksViewModel(
            collapseStore: UserDefaultsCollapseStateStore(defaults: suite))
        XCTAssertFalse(other.isExpanded(forKey: key))
    }
}
