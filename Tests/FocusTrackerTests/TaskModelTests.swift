import XCTest
@testable import FocusTracker

final class TaskModelTests: XCTestCase {
    // MARK: - Helpers

    private func makeTask(
        title: String = "Plan Q4 roadmap",
        categories: [FocusTracker.Category] = [FocusTracker.Category(name: "Planning"), FocusTracker.Category(name: "Work")],
        status: TaskStatus = .inProgress,
        project: Project? = Project(name: "Work"),
        subtasks: [SubtaskItem] = []
    ) throws -> TaskItem {
        try TaskItem(
            title: title,
            categories: categories,
            status: status,
            project: project,
            subtasks: subtasks
        )
    }

    private func makeSubtask(
        title: String,
        status: TaskStatus = .toDo,
        children: [SubtaskItem] = []
    ) -> SubtaskItem {
        SubtaskItem(title: title, status: status, children: children)
    }

    // MARK: - Construction

    func testTaskConstructionRequiresAtLeastOneCategory() throws {
        XCTAssertThrowsError(try TaskItem(title: "No category", categories: [])) { error in
            XCTAssertEqual(error as? TaskItem.ValidationError, .atLeastOneCategoryRequired)
        }
        let single = try TaskItem(title: "Single", categories: [FocusTracker.Category(name: "Admin")])
        XCTAssertEqual(single.categories.count, 1)
        let multiple = try makeTask()
        XCTAssertEqual(multiple.categories.map(\.name), ["Planning", "Work"])
    }

    func testTaskDefaultsAndOptionalFields() throws {
        let task = try TaskItem(title: "Minimal", categories: [FocusTracker.Category(name: "Admin")])
        XCTAssertNotNil(task.id)
        XCTAssertEqual(task.status, .toDo)
        XCTAssertNil(task.project)
        XCTAssertNil(task.priority)
        XCTAssertNil(task.effort)
        XCTAssertNil(task.deadline)
        XCTAssertNil(task.notes)
        XCTAssertTrue(task.subtasks.isEmpty)
    }

    // MARK: - Enum raw values (must match fixtures/sample-vault)

    func testStatusRawValuesMatchFixtures() {
        XCTAssertEqual(TaskStatus.toDo.rawValue, "To Do")
        XCTAssertEqual(TaskStatus.inProgress.rawValue, "In Progress")
        XCTAssertEqual(TaskStatus.blocked.rawValue, "Blocked")
        XCTAssertEqual(TaskStatus.dropped.rawValue, "Dropped")
        XCTAssertEqual(TaskStatus.done.rawValue, "Done")
        XCTAssertEqual(Set(TaskStatus.allCases).count, 5)
    }

    func testPriorityRawValuesMatchFixtures() {
        XCTAssertEqual(Priority.low.rawValue, "Low")
        XCTAssertEqual(Priority.medium.rawValue, "Medium")
        XCTAssertEqual(Priority.high.rawValue, "High")
        XCTAssertEqual(Set(Priority.allCases).count, 3)
    }

    func testEffortRawValuesMatchFixtures() {
        XCTAssertEqual(Effort.s.rawValue, "S")
        XCTAssertEqual(Effort.m.rawValue, "M")
        XCTAssertEqual(Effort.l.rawValue, "L")
        XCTAssertEqual(Effort.xl.rawValue, "XL")
        XCTAssertEqual(Set(Effort.allCases).count, 4)
    }

    func testCategoryAndProjectEncodeAsPlainStrings() throws {
        let categories = String(data: try JSONEncoder().encode([FocusTracker.Category(name: "Planning")]), encoding: .utf8)
        let project = String(data: try JSONEncoder().encode(Project(name: "Work")), encoding: .utf8)
        XCTAssertEqual(categories, #"["Planning"]"#)
        XCTAssertEqual(project, #""Work""#)
    }

    // MARK: - Recursive completion (pure function)

    func testCompletingLastNonDoneChildCompletesParent() throws {
        let first = makeSubtask(title: "Collect team input", status: .done)
        let last = makeSubtask(title: "Draft objectives")
        let task = try makeTask(subtasks: [first, last])

        let newlyDone = task.newlyDoneIDs(markingDone: last.id)

        XCTAssertEqual(newlyDone, [last.id, task.id])
    }

    func testThreeLevelChainBubblesUpThroughAllAncestors() throws {
        let leaf = makeSubtask(title: "Define Q4 objectives")
        let middle = makeSubtask(title: "Draft objectives and key results", children: [leaf])
        let top = makeSubtask(title: "Plan Q4 roadmap", children: [middle])
        let task = try makeTask(subtasks: [top])

        let newlyDone = task.newlyDoneIDs(markingDone: leaf.id)

        XCTAssertEqual(newlyDone, [leaf.id, middle.id, top.id, task.id])
    }

    func testNonDoneSiblingBlocksParentCompletion() throws {
        let completing = makeSubtask(title: "Collect team input")
        let sibling = makeSubtask(title: "Draft objectives")
        let task = try makeTask(subtasks: [completing, sibling])

        let newlyDone = task.newlyDoneIDs(markingDone: completing.id)

        XCTAssertEqual(newlyDone, [completing.id])
        XCTAssertFalse(newlyDone.contains(task.id))
    }

    func testAlreadyDoneParentStaysDoneAndIsNotReReported() throws {
        let doneParent = makeSubtask(title: "Already finished branch", status: .done)
        let leaf = makeSubtask(title: "Finish the last piece")
        let grandparent = makeSubtask(title: "Umbrella", children: [doneParent, leaf])
        let task = try makeTask(subtasks: [grandparent])

        let newlyDone = task.newlyDoneIDs(markingDone: leaf.id)

        // Bubbling completes the leaf, the grandparent, and the top-level
        // task — but the already-Done parent is never re-reported.
        XCTAssertEqual(newlyDone, [leaf.id, grandparent.id, task.id])
        XCTAssertFalse(newlyDone.contains(doneParent.id))
    }

    func testReCompletingAlreadyDoneLeafReturnsEmptySet() throws {
        let leaf = makeSubtask(title: "Collect team input", status: .done)
        let task = try makeTask(subtasks: [leaf])

        XCTAssertEqual(task.newlyDoneIDs(markingDone: leaf.id), [])
    }

    func testReCompletingAlreadyDoneTaskReturnsEmptySet() throws {
        let task = try makeTask(status: .done)
        XCTAssertEqual(task.newlyDoneIDs(markingDone: task.id), [])
    }

    func testStandaloneTaskCompletionReturnsOwnIDOnly() throws {
        let task = try makeTask(title: "Read Deep Work")

        let newlyDone = task.newlyDoneIDs(markingDone: task.id)

        XCTAssertEqual(newlyDone, [task.id])
    }

    func testUnknownIDReturnsEmptySet() throws {
        let task = try makeTask()
        XCTAssertEqual(task.newlyDoneIDs(markingDone: UUID()), [])
    }

    // MARK: - Ancestor inheritance (project/categories)

    func testEffectiveProjectAndCategoriesResolveAtThreeLevels() throws {
        let leaf = makeSubtask(title: "Define Q4 objectives")
        let middle = makeSubtask(title: "Draft objectives", children: [leaf])
        let top = makeSubtask(title: "Plan Q4 roadmap", children: [middle])
        let task = try makeTask(
            project: Project(name: "Work"),
            subtasks: [top]
        )

        XCTAssertEqual(task.effectiveProject(of: leaf.id), Project(name: "Work"))
        XCTAssertEqual(task.effectiveProject(of: middle.id), Project(name: "Work"))
        XCTAssertEqual(task.effectiveProject(of: top.id), Project(name: "Work"))
        XCTAssertEqual(task.effectiveProject(of: task.id), Project(name: "Work"))
        XCTAssertEqual(task.effectiveCategories(of: leaf.id).map(\.name), ["Planning", "Work"])
        XCTAssertEqual(task.effectiveCategories(of: middle.id).map(\.name), ["Planning", "Work"])
        XCTAssertEqual(task.effectiveCategories(of: top.id).map(\.name), ["Planning", "Work"])
    }

    func testEffectiveProjectAndCategoriesNilWhenTaskHasNone() throws {
        let leaf = makeSubtask(title: "Deep leaf")
        let middle = makeSubtask(title: "Middle", children: [leaf])
        let task = try TaskItem(
            title: "Read Deep Work",
            categories: [FocusTracker.Category(name: "Learning")],
            status: .dropped,
            subtasks: [middle]
        )

        XCTAssertNil(task.effectiveProject(of: leaf.id))
        XCTAssertNil(task.effectiveProject(of: task.id))
        XCTAssertEqual(task.effectiveCategories(of: leaf.id).map(\.name), ["Learning"])
    }

    func testEffectiveLookupForUnknownIDIsEmpty() throws {
        let task = try makeTask()
        XCTAssertNil(task.effectiveProject(of: UUID()))
        XCTAssertTrue(task.effectiveCategories(of: UUID()).isEmpty)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesNestedSubtasksAndSetOptionals() throws {
        let deadline = Date(timeIntervalSince1970: 1_792_099_200) // 2026-10-15T00:00:00Z
        let leaf = SubtaskItem(
            title: "Define Q4 objectives",
            status: .blocked,
            priority: .low,
            notes: "Waiting on final company goals."
        )
        let middle = SubtaskItem(
            title: "Draft objectives and key results",
            status: .inProgress,
            priority: .medium,
            effort: .m,
            deadline: deadline,
            notes: "Two passes needed.",
            children: [leaf]
        )
        let plainLeaf = SubtaskItem(title: "Collect team input", status: .done, notes: "Gathered via the weekly sync.")
        let task = try TaskItem(
            title: "Plan Q4 roadmap",
            categories: [FocusTracker.Category(name: "Planning"), FocusTracker.Category(name: "Work")],
            status: .inProgress,
            project: Project(name: "Work"),
            priority: .high,
            effort: .l,
            deadline: deadline,
            notes: "Draft the roadmap, then review.",
            subtasks: [middle, plainLeaf]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(task)
        let decoded = try decoder.decode(TaskItem.self, from: data)

        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.subtasks.count, 2)
        XCTAssertEqual(decoded.subtasks[0].children.count, 1)
        XCTAssertEqual(decoded.subtasks[0].children[0].id, leaf.id)
        XCTAssertEqual(decoded.subtasks[0].priority, .medium)
        XCTAssertEqual(decoded.subtasks[1].effort, nil)
    }

    func testCodableRoundTripDistinguishesNilFromSetOptionals() throws {
        let withValues = try TaskItem(
            title: "With values",
            categories: [FocusTracker.Category(name: "Admin")],
            status: .blocked,
            project: Project(name: "Admin"),
            priority: .high,
            effort: .xl,
            deadline: Date(timeIntervalSince1970: 1_792_963_200),
            notes: "Some notes."
        )
        let withNils = try TaskItem(
            title: "With nils",
            categories: [FocusTracker.Category(name: "Admin")],
            status: .toDo
        )

        let data = try JSONEncoder().encode([withValues, withNils])
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"project\":\"Admin\""))
        XCTAssertTrue(json.contains("\"priority\":\"High\""))
        XCTAssertTrue(json.contains("\"effort\":\"XL\""))
        XCTAssertTrue(json.contains("\"notes\":\"Some notes.\""))
        XCTAssertFalse(json.contains("\"project\":null"))
        XCTAssertFalse(json.contains("\"priority\":null"))

        let decoded = try JSONDecoder().decode([TaskItem].self, from: data)
        XCTAssertEqual(decoded[0], withValues)
        XCTAssertEqual(decoded[1], withNils)
        XCTAssertNotNil(decoded[0].deadline)
        XCTAssertNil(decoded[1].deadline)
        XCTAssertNotNil(decoded[0].project)
        XCTAssertNil(decoded[1].project)
    }

    func testCodableRoundTripUsesFixtureSubtasksKeyForChildren() throws {
        let leaf = SubtaskItem(title: "Leaf")
        let middle = SubtaskItem(title: "Middle", children: [leaf])
        let task = try TaskItem(
            title: "Root",
            categories: [FocusTracker.Category(name: "Planning")],
            subtasks: [middle]
        )

        let json = String(data: try JSONEncoder().encode(task), encoding: .utf8)!

        XCTAssertTrue(json.contains("\"subtasks\":"))
        XCTAssertFalse(json.contains("\"children\":"))

        let decoded = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.subtasks[0].children[0], leaf)
    }
}
