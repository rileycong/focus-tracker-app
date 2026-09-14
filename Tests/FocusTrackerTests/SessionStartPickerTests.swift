import XCTest
@testable import FocusTracker

// File-local alias: the refusal type is nested in `AppModel`.
private typealias SessionStartRefusal = AppModel.SessionStartRefusal

/// Tests for the #19 session-start picker's pure logic (issue #19 "pure
/// picker-filtering logic" criterion — no SwiftUI, no I/O, same spirit as
/// `TasksGroupingTests`): eligibility (NOT Blocked/Dropped/Done — the #9
/// planning-eligible rule, per-node), the any-depth subtask flattening, the
/// tasks-view-like grouping (project sections sorted, No Project last,
/// status sub-groups in the pinned order), the search filter, and the
/// sheet's two pure helpers (duration parsing, refusal copy).
final class SessionStartPickerTests: XCTestCase {

    // MARK: - Fixtures

    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()
    private static let s1 = UUID()
    private static let s2 = UUID()
    private static let s3 = UUID()
    private static let deep = UUID()

    private static let work = Project(name: "Work")
    private static let home = Project(name: "Home")
    private static let alpha = Project(name: "Alpha")

    private func task(
        _ id: UUID, title: String? = nil, project: Project? = nil,
        status: TaskStatus = .toDo, subtasks: [SubtaskItem] = []
    ) -> TaskItem {
        try! TaskItem(
            id: id, title: title ?? id.uuidString, categories: [Category(name: "C")],
            status: status, project: project, subtasks: subtasks)
    }

    private func subtask(
        _ id: UUID, title: String? = nil, status: TaskStatus = .toDo,
        children: [SubtaskItem] = []
    ) -> SubtaskItem {
        SubtaskItem(id: id, title: title ?? id.uuidString, status: status, children: children)
    }

    private func ids(_ targets: [SessionStartTarget]) -> [UUID] {
        targets.map(\.id)
    }

    // MARK: - Pre-selection (issue #34)

    func testPreselectionReturnsAnEligibleRequestedID() {
        let tasks = [
            task(Self.a, status: .toDo),
            task(Self.b, status: .inProgress),
        ]
        XCTAssertEqual(
            SessionStartPicker.preselectedTargetID(requesting: Self.b, in: tasks),
            Self.b, "an eligible ID pre-selects itself")
        XCTAssertEqual(
            SessionStartPicker.preselectedTargetID(requesting: Self.a, in: tasks),
            Self.a)
    }

    func testPreselectionIsClearedForDoneBlockedDroppedAndAbsentIDs() {
        let tasks = [
            task(Self.a, status: .done),
            task(Self.b, status: .blocked),
            task(Self.c, status: .dropped),
        ]
        XCTAssertNil(
            SessionStartPicker.preselectedTargetID(requesting: Self.a, in: tasks),
            "Done previous task → no pre-selection")
        XCTAssertNil(
            SessionStartPicker.preselectedTargetID(requesting: Self.b, in: tasks),
            "Blocked previous task → no pre-selection")
        XCTAssertNil(
            SessionStartPicker.preselectedTargetID(requesting: Self.c, in: tasks),
            "Dropped previous task → no pre-selection")
        XCTAssertNil(
            SessionStartPicker.preselectedTargetID(requesting: UUID(), in: tasks),
            "absent previous task → no pre-selection")
    }

    func testPreselectionIsNilWithoutARequest() {
        let tasks = [task(Self.a, status: .toDo)]
        XCTAssertNil(
            SessionStartPicker.preselectedTargetID(requesting: nil, in: tasks),
            "no request → the current #19 behavior (unselected picker)")
    }

    func testPreselectionAcceptsAnEligibleSubtaskAtAnyDepth() {
        let tasks = [
            task(Self.a, subtasks: [
                subtask(Self.s1, children: [subtask(Self.deep)]),
            ]),
        ]
        XCTAssertEqual(
            SessionStartPicker.preselectedTargetID(requesting: Self.s1, in: tasks),
            Self.s1)
        XCTAssertEqual(
            SessionStartPicker.preselectedTargetID(requesting: Self.deep, in: tasks),
            Self.deep)
    }


    // MARK: - Eligibility: tasks

    func testToDoAndInProgressTasksAreEligible() {
        let targets = SessionStartPicker.eligibleTargets(in: [
            task(Self.a, status: .toDo),
            task(Self.b, status: .inProgress),
        ])
        XCTAssertEqual(ids(targets), [Self.a, Self.b])
    }

    func testBlockedDroppedAndDoneTasksAreExcluded() {
        let targets = SessionStartPicker.eligibleTargets(in: [
            task(Self.a, status: .blocked),
            task(Self.b, status: .dropped),
            task(Self.c, status: .done),
        ])
        XCTAssertTrue(targets.isEmpty, "the #9 refusals .blocked/.dropped/.alreadyDone map to picker exclusion")
    }

    // MARK: - Eligibility: subtasks at any depth (own-status rule)

    func testEligibleSubtasksAtAnyDepthAreIncluded() {
        // depth 1 (s1) and depth 2 (deep) eligible; parent task To Do.
        let targets = SessionStartPicker.eligibleTargets(in: [
            task(
                Self.a, title: "Parent", subtasks: [
                    subtask(Self.s1, title: "Child", children: [
                        subtask(Self.deep, title: "Grandchild"),
                    ]),
                    subtask(Self.s2, title: "Blocked child", status: .blocked),
                ])
        ])
        XCTAssertEqual(
            ids(targets), [Self.a, Self.s1, Self.deep],
            "tasks first, then eligible subtasks depth-first; the Blocked subtask is excluded")
        XCTAssertEqual(targets.first { $0.id == Self.deep }?.depth, 2)
        XCTAssertEqual(
            targets.first { $0.id == Self.deep }?.path,
            ["Parent", "Child", "Grandchild"])
    }

    func testSubtaskEligibilityIsByOwnStatusOnly() {
        // A To Do subtask under a Done parent is still eligible (#9's pinned
        // per-node state rule; well-formed vaults can't produce this, but
        // externally authored files can) — and the In-Progress parent in the
        // second tree is itself a target while its Dropped child is not.
        let targets = SessionStartPicker.eligibleTargets(in: [
            task(Self.a, status: .done, subtasks: [
                subtask(Self.s1, status: .toDo),
            ]),
            task(Self.b, status: .inProgress, subtasks: [
                subtask(Self.s2, status: .dropped),
            ]),
        ])
        XCTAssertEqual(ids(targets), [Self.s1, Self.b])
    }

    func testSubtaskTargetsInheritParentProjectAndCategories() {
        let targets = SessionStartPicker.eligibleTargets(in: [
            task(
                Self.a, project: Self.work, subtasks: [
                    subtask(Self.s1),
                ])
        ])
        let sub = targets.first { $0.id == Self.s1 }
        XCTAssertEqual(sub?.project, Self.work)
        XCTAssertEqual(sub?.categories, [Category(name: "C")])
        XCTAssertEqual(sub?.parentTaskID, Self.a)
        XCTAssertEqual(sub?.parentTaskTitle, targets.first { $0.id == Self.a }?.title)
    }

    // MARK: - Grouping

    func testSectionsGroupByProjectSortedWithNoProjectLast() {
        let sections = SessionStartPicker.sections(in: [
            task(Self.a, project: Self.home),
            task(Self.b, project: nil),
            task(Self.c, project: Self.work),
        ])
        XCTAssertEqual(sections.map(\.displayName), ["Home", "Work", "No Project"])
    }

    func testNoProjectSectionAbsentWhenEveryTargetHasAProject() {
        let sections = SessionStartPicker.sections(in: [
            task(Self.a, project: Self.work), task(Self.b, project: Self.work),
        ])
        XCTAssertEqual(sections.map(\.displayName), ["Work"])
    }

    func testStatusSubGroupsInPinnedOrderAndOnlyWhenNonEmpty() {
        let sections = SessionStartPicker.sections(in: [
            task(Self.a, project: Self.work, status: .inProgress),
            task(Self.b, project: Self.work, status: .toDo),
            task(Self.c, project: nil, status: .toDo),
        ])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(
            sections[0].groups.map(\.status), [.toDo, .inProgress],
            "the pinned tasks-view order's eligible subset: To Do before In Progress")
        XCTAssertEqual(sections[0].groups.map { $0.targets.map(\.id) }, [[Self.b], [Self.a]])
        XCTAssertEqual(sections[1].groups.map(\.status), [.toDo], "empty groups are omitted")
    }

    func testSectionAppearsOnlyWhenItHasAnEligibleTarget() {
        // A done-only project produces no section (its only task is excluded).
        let sections = SessionStartPicker.sections(in: [
            task(Self.a, project: Self.work, status: .done),
            task(Self.b, project: Self.home, status: .toDo),
        ])
        XCTAssertEqual(sections.map(\.displayName), ["Home"])
    }

    func testSubtaskTargetsLandInTheirParentsProjectSection() {
        let sections = SessionStartPicker.sections(in: [
            task(Self.a, project: Self.work, subtasks: [
                subtask(Self.s1),
            ]),
        ])
        XCTAssertEqual(sections.count, 1)
        let groupTargets = sections[0].groups.flatMap(\.targets)
        XCTAssertEqual(ids(groupTargets), [Self.a, Self.s1], "parent followed by its subtask")
    }

    func testInventoryTreeOrderPreservedWithinGroups() {
        // All To Do, no projects: the group lists tasks in inventory order.
        let sections = SessionStartPicker.sections(in: [
            task(Self.b, title: "B"), task(Self.a, title: "A"),
        ])
        XCTAssertEqual(ids(sections[0].groups[0].targets), [Self.b, Self.a])
    }

    func testEmptyInventoryYieldsNoSections() {
        XCTAssertEqual(SessionStartPicker.sections(in: []), [])
        XCTAssertEqual(
            SessionStartPicker.sections(in: [task(Self.a, status: .done)]), [])
    }

    // MARK: - Search

    func testSearchMatchesOwnTitleCaseInsensitively() {
        let targets = SessionStartPicker.eligibleTargets(in: [
            task(Self.a, title: "Plan Q4 roadmap"),
            task(Self.b, title: "Renew passport"),
        ])
        let filtered = targets.filter { SessionStartPicker.matches($0, query: "ROADMAP") }
        XCTAssertEqual(ids(filtered), [Self.a])
    }

    func testSearchMatchesOwningTaskTitleForSubtasks() {
        let targets = SessionStartPicker.eligibleTargets(in: [
            task(Self.a, title: "Plan Q4 roadmap", subtasks: [
                subtask(Self.s1, title: "Draft objectives"),
            ]),
        ])
        let byParent = targets.filter {
            SessionStartPicker.matches($0, query: "roadmap")
        }
        XCTAssertEqual(Set(ids(byParent)), [Self.a, Self.s1])
        let byOwn = targets.filter {
            SessionStartPicker.matches($0, query: "objectives")
        }
        XCTAssertEqual(ids(byOwn), [Self.s1])
    }

    func testEmptyAndWhitespaceQueryMatchesEverything() {
        let targets = SessionStartPicker.eligibleTargets(in: [
            task(Self.a, title: "Anything"),
        ])
        XCTAssertTrue(targets.allSatisfy { SessionStartPicker.matches($0, query: "") })
        XCTAssertTrue(targets.allSatisfy { SessionStartPicker.matches($0, query: "   ") })
    }

    func testSearchWithNoMatchesYieldsNoSections() {
        let sections = SessionStartPicker.sections(
            in: [task(Self.a, title: "Plan Q4 roadmap")], matching: "zebra")
        XCTAssertEqual(sections, [])
    }

    func testSearchFiltersWithinGroupsKeepingStructure() {
        let sections = SessionStartPicker.sections(
            in: [
                task(Self.a, title: "Alpha plan", project: Self.work),
                task(Self.b, title: "Beta plan", project: Self.work),
                task(Self.c, title: "Gamma write", project: Self.home),
            ],
            matching: "plan")
        XCTAssertEqual(sections.map(\.displayName), ["Work"])
        XCTAssertEqual(ids(sections[0].groups[0].targets), [Self.a, Self.b])
    }
}

/// Tests for the #19 sheet's pure helpers (no SwiftUI instantiation):
/// duration-field parsing and the typed-refusal inline copy.
final class SessionStartFormLogicTests: XCTestCase {

    // MARK: - Duration parsing (positive whole minutes only)

    func testDefaultAndPlainPositiveValuesParse() {
        XCTAssertEqual(SessionStartView.parseDurationMinutes("25"), 25)
        XCTAssertEqual(SessionStartView.parseDurationMinutes("1"), 1)
        XCTAssertEqual(SessionStartView.parseDurationMinutes(" 42 "), 42)
    }

    func testInvalidDurationInputsAreRefused() {
        XCTAssertNil(SessionStartView.parseDurationMinutes(""), "empty")
        XCTAssertNil(SessionStartView.parseDurationMinutes("   "), "whitespace only")
        XCTAssertNil(SessionStartView.parseDurationMinutes("abc"), "non-numeric")
        XCTAssertNil(SessionStartView.parseDurationMinutes("0"), "zero")
        XCTAssertNil(SessionStartView.parseDurationMinutes("-5"), "negative")
        XCTAssertNil(SessionStartView.parseDurationMinutes("25.5"), "fractional")
        // (A leading "+" is `Int`'s accepted positive sign — "＋3" is the
        // positive integer 3, so it parses and starts a 3-minute session.)
    }

    // MARK: - Refusal copy (each typed case gets distinct inline text)

    func testEveryRefusalCaseHasDistinctNonEmptyCopy() {
        let id = UUID()
        let messages: [SessionStartRefusal] = [
            .sessionAlreadyActive,
            .vaultNotConfigured,
            .pendingRecoveryUnresolved,
            .unknownTarget(id),
            .targetRefused(id, .blocked),
            .targetRefused(id, .dropped),
            .targetRefused(id, .alreadyDone),
            .adHocTaskInvalid,
            .adHocCreationFailed(.unknownTaskID(id)),
        ]
        let copies = messages.map { SessionStartView.refusalMessage($0) }
        XCTAssertTrue(copies.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(copies).count, copies.count, "no two refusals share copy")
    }

}
