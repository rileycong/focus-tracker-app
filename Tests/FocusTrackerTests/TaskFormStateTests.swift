import XCTest
@testable import FocusTracker

/// Pure-logic tests for the #16 task form state (`TaskFormState` in
/// `Views/`): validation (title required with whitespace-only = empty,
/// ≥1 category), the inline-category commit rules (trimming,
/// whitespace-only drafts, case-insensitive dedupe, comma segments), the
/// `TaskItem` ↔ form-state mapping with its round-trip guarantee
/// (all fields, nil-vs-set optionals), and the inventory name gathering.
/// No I/O anywhere — the type's pinned contract.
final class TaskFormStateTests: XCTestCase {

    // MARK: - Helpers

    private let deadline = DeadlineDay.date(from: "2026-11-01")

    private func makeFullTask() throws -> TaskItem {
        try TaskItem(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Plan the offsite",
            categories: [Category(name: "Planning"), Category(name: "Team")],
            status: .inProgress,
            project: Project(name: "Work"),
            priority: .high,
            effort: .l,
            deadline: deadline,
            notes: "Book the venue first.",
            order: 3,
            subtasks: [
                SubtaskItem(
                    id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                    title: "Collect input",
                    status: .done,
                    priority: .low,
                    effort: .s,
                    deadline: deadline,
                    notes: "Done in the sync.",
                    children: [
                        SubtaskItem(
                            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
                            title: "Nested child",
                            status: .blocked)
                    ])
            ])
    }

    // MARK: - Blank defaults

    func testBlankFormDefaultsToToDoWithNoCategoriesAndUnsetOptionals() {
        let state = TaskFormState()

        XCTAssertEqual(state.title, "")
        XCTAssertTrue(state.categoryNames.isEmpty)
        XCTAssertEqual(state.status, .toDo, "the default status is To Do (issue #16)")
        XCTAssertNil(state.projectName)
        XCTAssertNil(state.priority)
        XCTAssertNil(state.effort)
        XCTAssertNil(state.deadline)
        XCTAssertNil(state.notes)
        XCTAssertFalse(state.isValid, "a blank form is not saveable")
    }

    // MARK: - Validation

    func testEmptyTitleIsInvalid() {
        var state = TaskFormState()
        state.commitCategory("Work")

        XCTAssertFalse(state.hasValidTitle)
        XCTAssertFalse(state.isValid, "empty title blocks save")
    }

    func testWhitespaceOnlyTitleIsInvalid() {
        var state = TaskFormState()
        state.title = "   \t\n  "
        state.commitCategory("Work")

        XCTAssertFalse(state.hasValidTitle, "whitespace-only counts as empty")
        XCTAssertFalse(state.isValid)
    }

    func testZeroCategoriesIsInvalid() {
        var state = TaskFormState()
        state.title = "Real title"

        XCTAssertTrue(state.hasValidTitle)
        XCTAssertFalse(state.hasValidCategories, "at least one category is required (§6.3)")
        XCTAssertFalse(state.isValid)
    }

    func testValidTitleWithOneCategoryIsValid() {
        var state = TaskFormState()
        state.title = "Real title"
        state.commitCategory("Work")

        XCTAssertTrue(state.isValid)
    }

    // MARK: - Inline category commit

    func testWhitespaceOnlyCategoryDraftCreatesNoToken() {
        var state = TaskFormState()

        XCTAssertFalse(state.commitCategory("   "))
        XCTAssertTrue(state.categoryNames.isEmpty, "whitespace-only drafts are dropped")

        state.categoryDraft = "  \t "
        XCTAssertFalse(state.commitWholeDraft())
        XCTAssertTrue(state.categoryNames.isEmpty)
        XCTAssertEqual(state.categoryDraft, "", "the field clears either way")
    }

    func testCategoryCommitTrimsWhitespace() {
        var state = TaskFormState()

        XCTAssertTrue(state.commitCategory("  Work \n"))
        XCTAssertEqual(state.categoryNames, ["Work"])
    }

    func testCategoryCommitDeduplicatesCaseInsensitively() {
        var state = TaskFormState()
        state.commitCategory("Work")

        XCTAssertFalse(state.commitCategory("WORK"), "same label, different case")
        XCTAssertFalse(state.commitCategory("work"))
        XCTAssertEqual(state.categoryNames, ["Work"], "no duplicate tokens")
    }

    func testCommaSegmentsCommitCompletedOnesAndKeepTrailingDraft() {
        var state = TaskFormState()
        state.categoryDraft = "Work, Planning"

        state.commitCompletedCategorySegments()

        XCTAssertEqual(state.categoryNames, ["Work"], "the comma-completed segment commits")
        XCTAssertEqual(state.categoryDraft, "Planning", "the trailing segment stays in the field")
    }

    func testTrailingCommaCommitsEverythingAndClearsDraft() {
        var state = TaskFormState()
        state.categoryDraft = "Work, Planning, "

        state.commitCompletedCategorySegments()

        XCTAssertEqual(state.categoryNames, ["Work", "Planning"])
        XCTAssertEqual(state.categoryDraft, "")
    }

    func testEmptyCommaSegmentsAreDropped() {
        var state = TaskFormState()
        state.categoryDraft = ",,  , Work,,"

        state.commitCompletedCategorySegments()

        XCTAssertEqual(state.categoryNames, ["Work"], "empty segments never become tokens")
    }

    func testCommaCommitWithNoCommaIsANoOp() {
        var state = TaskFormState()
        state.categoryDraft = "Work"

        state.commitCompletedCategorySegments()

        XCTAssertTrue(state.categoryNames.isEmpty, "nothing commits without Enter or a comma")
        XCTAssertEqual(state.categoryDraft, "Work")
    }

    func testWholeDraftCommitsAndClears() {
        var state = TaskFormState()
        state.categoryDraft = "  Work  "

        XCTAssertTrue(state.commitWholeDraft())
        XCTAssertEqual(state.categoryNames, ["Work"])
        XCTAssertEqual(state.categoryDraft, "")
    }

    func testWholeDraftDuplicateClearsWithoutAdding() {
        var state = TaskFormState()
        state.commitCategory("Work")
        state.categoryDraft = "work"

        XCTAssertFalse(state.commitWholeDraft())
        XCTAssertEqual(state.categoryNames, ["Work"])
        XCTAssertEqual(state.categoryDraft, "", "the field clears — the token is already there")
    }

    func testRemoveCategoryDeletesTheToken() {
        var state = TaskFormState()
        state.commitCategory("Work")
        state.commitCategory("Planning")

        state.removeCategory("Work")

        XCTAssertEqual(state.categoryNames, ["Planning"])
    }

    // MARK: - Mapping: TaskItem → form state → TaskItem (round trip)

    func testRoundTripPreservesAllSetFields() throws {
        let original = try makeFullTask()

        let rebuilt = try TaskFormState(task: original).makeTask(preserving: original)

        XCTAssertEqual(rebuilt, original, "state → task → state keeps every field")
    }

    func testRoundTripPreservesAllNilOptionals() throws {
        let original = try TaskItem(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Minimal task", categories: [Category(name: "Inbox")])

        let state = TaskFormState(task: original)
        XCTAssertNil(state.projectName)
        XCTAssertNil(state.priority)
        XCTAssertNil(state.effort)
        XCTAssertNil(state.deadline)
        XCTAssertNil(state.notes)

        let rebuilt = try state.makeTask(preserving: original)
        XCTAssertEqual(rebuilt, original)
        XCTAssertNil(rebuilt.project)
        XCTAssertNil(rebuilt.priority)
        XCTAssertNil(rebuilt.effort)
        XCTAssertNil(rebuilt.deadline)
        XCTAssertNil(rebuilt.notes)
    }

    func testNilVersusSetOptionalsStayDistinctInMapping() throws {
        // nil notes vs set-but-empty notes: the mapping is identity on the
        // stored value, so both survive (the editor binding maps empty text
        // to nil at the UI layer only).
        let nilNotes = try TaskItem(
            title: "A", categories: [Category(name: "Inbox")], notes: nil)
        let emptyNotes = try TaskItem(
            title: "B", categories: [Category(name: "Inbox")], notes: "")
        let dated = try TaskItem(
            title: "C", categories: [Category(name: "Inbox")], deadline: deadline)

        let rebuiltNil = try TaskFormState(task: nilNotes).makeTask(preserving: nilNotes)
        let rebuiltEmpty = try TaskFormState(task: emptyNotes).makeTask(preserving: emptyNotes)
        let rebuiltDated = try TaskFormState(task: dated).makeTask(preserving: dated)

        XCTAssertNil(rebuiltNil.notes)
        XCTAssertEqual(rebuiltEmpty.notes, "", "set-empty stays set-empty")
        XCTAssertEqual(rebuiltDated.deadline, deadline)
        XCTAssertNotEqual(rebuiltNil, rebuiltEmpty, "nil and set are distinct states")
    }

    // MARK: - Mapping: form state → TaskItem

    func testMakeTaskForCreateAssignsFreshIdentity() throws {
        var state = TaskFormState()
        state.title = "Fresh task"
        state.commitCategory("Inbox")

        let created = try state.makeTask(preserving: nil)

        XCTAssertEqual(created.title, "Fresh task")
        XCTAssertEqual(created.categories.map(\.name), ["Inbox"])
        XCTAssertEqual(created.status, .toDo)
        XCTAssertTrue(created.subtasks.isEmpty, "a new task starts with no subtasks")
        XCTAssertNil(created.order, "a new task starts unordered")
    }

    func testMakeTaskForEditKeepsIDOrderAndSubtasks() throws {
        let original = try makeFullTask()
        var state = TaskFormState(task: original)
        state.title = "Renamed offsite"
        state.status = .blocked

        let updated = try state.makeTask(preserving: original)

        XCTAssertEqual(updated.id, original.id, "the ID addresses the file — never regenerated")
        XCTAssertEqual(updated.order, original.order)
        XCTAssertEqual(updated.subtasks, original.subtasks, "subtasks are not form-editable")
        XCTAssertEqual(updated.title, "Renamed offsite")
        XCTAssertEqual(updated.status, .blocked)
    }

    func testMakeTaskTrimsTitleAndTreatsWhitespaceProjectAsNone() throws {
        var state = TaskFormState()
        state.title = "  Padded title  "
        state.commitCategory("Inbox")
        state.projectName = "   "

        let task = try state.makeTask(preserving: nil)

        XCTAssertEqual(task.title, "Padded title")
        XCTAssertNil(task.project, "a whitespace-only project name is no project")
    }

    func testMakeTaskThrowsWithoutCategories() {
        var state = TaskFormState()
        state.title = "Real title"

        XCTAssertThrowsError(try state.makeTask(preserving: nil)) { error in
            XCTAssertEqual(
                error as? TaskItem.ValidationError, .atLeastOneCategoryRequired,
                "the model's own invariant backs the form's validation")
        }
    }

    func testMakeTaskAcceptsEveryStatusIncludingDone() throws {
        // §8.5 says "status required", not "status restricted": creating with
        // any of the five statuses — including `Done` — is allowed.
        for status in TaskStatus.allCases {
            var state = TaskFormState()
            state.title = "Any status"
            state.commitCategory("Inbox")
            state.status = status

            let task = try state.makeTask(preserving: nil)
            XCTAssertEqual(task.status, status)
        }
    }

    // MARK: - Inventory gathering

    func testKnownCategoryNamesDeduplicateCaseInsensitivelyAndSort() {
        let tasks = [
            try! TaskItem(
                title: "One",
                categories: [Category(name: "Work"), Category(name: "Planning")]),
            try! TaskItem(title: "Two", categories: [Category(name: "work")]),
            try! TaskItem(title: "Three", categories: [Category(name: "Personal")]),
        ]

        let names = TaskFormState.knownCategoryNames(in: tasks)

        XCTAssertEqual(
            names, ["Personal", "Planning", "Work"],
            "case-insensitive dedupe keeps the first spelling, sorted for the combobox")
    }

    func testKnownProjectNamesAreSortedAndUnique() throws {
        let tasks = [
            try TaskItem(
                title: "One", categories: [Category(name: "Inbox")],
                project: Project(name: "Writing")),
            try TaskItem(
                title: "Two", categories: [Category(name: "Inbox")],
                project: Project(name: "Writing")),
            try TaskItem(
                title: "Three", categories: [Category(name: "Inbox")],
                project: Project(name: "Admin")),
            try TaskItem(title: "Four", categories: [Category(name: "Inbox")]),
        ]

        let names = TaskFormState.knownProjectNames(in: tasks)

        XCTAssertEqual(names, ["Admin", "Writing"], "No Project tasks contribute nothing")
    }
}
