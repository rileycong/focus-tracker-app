import XCTest
@testable import FocusTracker

/// Pure-function tests for the #9 status-transition core (`StatusTransition`),
/// mirroring every §6.5 rule. No file I/O, no store — decisions over in-memory
/// task trees, asserted with exact `Equatable` outcomes (never string
/// matching). The VaultStore wrapper integration lives in
/// `VaultStoreTransitionTests`.
final class StatusTransitionTests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(
        title: String = "Plan Q4 roadmap",
        status: TaskStatus = .toDo,
        subtasks: [SubtaskItem] = []
    ) throws -> TaskItem {
        try TaskItem(
            title: title,
            categories: [Category(name: "Planning")],
            status: status,
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

    private func assertApply(
        _ tree: TaskItem, changes: Set<UUID>, to status: TaskStatus, becomes: TaskStatus,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let applied = tree.applying(status: status, to: changes)
        XCTAssertEqual(applied.status, becomes, file: file, line: line)
    }

    // MARK: - startSession: all five statuses (PRD §6.5)

    func testStartSessionFromToDoTransitionsToInProgress() throws {
        let task = try makeTask(status: .toDo)

        XCTAssertEqual(StatusTransition.startSession(of: task.id, in: task), .transitioned([task.id]))
        assertApply(task, changes: [task.id], to: .inProgress, becomes: .inProgress)
    }

    func testStartSessionFromInProgressIsAnAllowedNoOp() throws {
        let task = try makeTask(status: .inProgress)

        // Empty change set = legitimate no-op: the session proceeds, nothing
        // changes. Not a refusal.
        XCTAssertEqual(StatusTransition.startSession(of: task.id, in: task), .transitioned([]))
    }

    func testStartSessionFromBlockedIsRefused() throws {
        let task = try makeTask(status: .blocked)

        XCTAssertEqual(StatusTransition.startSession(of: task.id, in: task), .refused(.blocked))
    }

    func testStartSessionFromDroppedIsRefused() throws {
        let task = try makeTask(status: .dropped)

        XCTAssertEqual(StatusTransition.startSession(of: task.id, in: task), .refused(.dropped))
    }

    func testStartSessionFromDoneIsRefusedAsAlreadyDone() throws {
        let task = try makeTask(status: .done)

        XCTAssertEqual(
            StatusTransition.startSession(of: task.id, in: task), .refused(.alreadyDone))
    }

    func testStartSessionAddressesSubtasksAtDepth() throws {
        let leaf = makeSubtask(title: "Define Q4 objectives")
        let middle = makeSubtask(title: "Draft OKRs", children: [leaf])
        let task = try makeTask(status: .blocked, subtasks: [middle])

        // The tree's own status (Blocked here) must not leak into the
        // subtarget's decision — the leaf's own To Do governs.
        XCTAssertEqual(StatusTransition.startSession(of: leaf.id, in: task), .transitioned([leaf.id]))
        XCTAssertEqual(StatusTransition.startSession(of: middle.id, in: task), .transitioned([middle.id]))
    }

    func testStartSessionWithUnknownIDIsADistinctTypedOutcome() throws {
        let task = try makeTask(status: .toDo)
        let unknown = UUID()

        XCTAssertEqual(
            StatusTransition.startSession(of: unknown, in: task), .unknownID(unknown))
        // Distinct from both an allowed no-op and a refusal — never a silent
        // empty set:
        XCTAssertNotEqual(
            StatusTransition.startSession(of: unknown, in: task), .transitioned([]))
        XCTAssertNotEqual(
            StatusTransition.startSession(of: unknown, in: task), .refused(.alreadyDone))
    }

    // MARK: - Refusal contract: typed, Equatable, exact reasons

    func testRefusalReasonsAreDistinctTypedValues() throws {
        let blocked = try makeTask(status: .blocked)
        let dropped = try makeTask(status: .dropped)
        let done = try makeTask(status: .done)

        XCTAssertEqual(StatusTransition.startSession(of: blocked.id, in: blocked), .refused(.blocked))
        XCTAssertEqual(StatusTransition.startSession(of: dropped.id, in: dropped), .refused(.dropped))
        XCTAssertEqual(StatusTransition.startSession(of: done.id, in: done), .refused(.alreadyDone))

        XCTAssertNotEqual(StatusTransition.Refusal.blocked, StatusTransition.Refusal.dropped)
        XCTAssertNotEqual(StatusTransition.Refusal.dropped, StatusTransition.Refusal.alreadyDone)
        XCTAssertNotEqual(StatusTransition.Refusal.blocked, StatusTransition.Refusal.alreadyDone)

        // A refusal is never an allowed transition (even an empty one):
        XCTAssertNotEqual(StatusTransition.startSession(of: blocked.id, in: blocked), .transitioned([]))
    }

    // MARK: - complete: recursive bubble-up (reuses #3's newlyDoneIDs)

    func testCompleteBubblesUpThroughADeepChainInOneChangeSet() throws {
        // task → child → grandchild → great-grandchild (≥ 3 subtask levels).
        let greatGrandchild = makeSubtask(title: "Great-grandchild")
        let grandchild = makeSubtask(title: "Grandchild", children: [greatGrandchild])
        let child = makeSubtask(title: "Child", children: [grandchild])
        let task = try makeTask(subtasks: [child])

        let outcome = StatusTransition.complete(greatGrandchild.id, in: task)

        XCTAssertEqual(
            outcome,
            .transitioned([greatGrandchild.id, grandchild.id, child.id, task.id]))

        // The whole change set applied at once flips every level to Done:
        guard case .transitioned(let changed) = outcome else {
            return XCTFail("expected .transitioned")
        }
        let applied = task.applying(status: .done, to: changed)
        XCTAssertEqual(applied.status, .done)
        XCTAssertEqual(applied.subtasks[0].status, .done)
        XCTAssertEqual(applied.subtasks[0].children[0].status, .done)
        XCTAssertEqual(applied.subtasks[0].children[0].children[0].status, .done)
    }

    func testCompleteWithMixedSiblingsBlocksParentThenReleases() throws {
        // A sibling still To Do / In Progress / Blocked holds the parent open;
        // completing the last sibling completes the parent.
        for siblingStatus in [TaskStatus.toDo, .inProgress, .blocked] {
            let target = makeSubtask(title: "Collect team input")
            let sibling = makeSubtask(title: "Draft objectives", status: siblingStatus)
            let task = try makeTask(subtasks: [target, sibling])

            XCTAssertEqual(
                StatusTransition.complete(target.id, in: task),
                .transitioned([target.id]),
                "sibling status \(siblingStatus.rawValue) must hold the parent open")

            // Completing the LAST sibling (the target is now Done) bubbles
            // up to the parent:
            let afterTarget = task.applying(status: .done, to: [target.id])
            XCTAssertEqual(
                StatusTransition.complete(sibling.id, in: afterTarget),
                .transitioned([sibling.id, task.id]),
                "sibling status \(siblingStatus.rawValue)")
        }
    }

    func testCompletePartiallyDoneSiblingsStillBubblesToTask() throws {
        let doneSibling = makeSubtask(title: "Collect team input", status: .done)
        let lastToDo = makeSubtask(title: "Draft objectives")
        let task = try makeTask(subtasks: [doneSibling, lastToDo])

        let outcome = StatusTransition.complete(lastToDo.id, in: task)
        XCTAssertEqual(outcome, .transitioned([lastToDo.id, task.id]))
        // Already-Done nodes are never re-reported:
        if case .transitioned(let changed) = outcome {
            XCTAssertFalse(changed.contains(doneSibling.id))
        }
    }

    func testCompleteAlreadyDoneTargetIsEmptyChangeSetNotAnError() throws {
        let task = try makeTask(status: .done)
        let doneLeaf = makeSubtask(title: "Collect team input", status: .done)
        let parent = try makeTask(subtasks: [doneLeaf])

        XCTAssertEqual(StatusTransition.complete(task.id, in: task), .transitioned([]))
        XCTAssertEqual(
            StatusTransition.complete(doneLeaf.id, in: parent), .transitioned([]))
    }

    func testCompleteUnknownIDIsTypedOutcome() throws {
        let task = try makeTask()
        let unknown = UUID()

        XCTAssertEqual(StatusTransition.complete(unknown, in: task), .unknownID(unknown))
    }

    func testCompleteAllowedFromAnyActiveStatusIncludingBlockedAndDropped() throws {
        // Documented decision: completion has no pinned refusal — finishing a
        // Blocked/Dropped node's work is a legitimate end-of-session outcome
        // (§6.5 "Completed task: Yes"), and a Blocked sibling must be
        // completable to release its parent (mixed-sibling rule).
        for current in [TaskStatus.blocked, .dropped, .inProgress, .toDo] {
            let task = try makeTask(status: current)
            XCTAssertEqual(
                StatusTransition.complete(task.id, in: task),
                .transitioned([task.id]),
                "from \(current.rawValue)")
        }
    }

    // MARK: - unblock: the only path out of Blocked

    func testUnblockMovesBlockedToToDoThenStartSessionWorks() throws {
        let task = try makeTask(status: .blocked)

        XCTAssertEqual(StatusTransition.unblock(task.id, in: task), .transitioned([task.id]))
        assertApply(task, changes: [task.id], to: .toDo, becomes: .toDo)

        // After unblocking (To Do), a session can start:
        let unblocked = task.applying(status: .toDo, to: [task.id])
        XCTAssertEqual(
            StatusTransition.startSession(of: task.id, in: unblocked), .transitioned([task.id]))
    }

    func testUnblockAddressesBlockedSubtaskAtDepth() throws {
        let leaf = makeSubtask(title: "Define Q4 objectives", status: .blocked)
        let middle = makeSubtask(title: "Draft OKRs", children: [leaf])
        let task = try makeTask(status: .inProgress, subtasks: [middle])

        XCTAssertEqual(StatusTransition.unblock(leaf.id, in: task), .transitioned([leaf.id]))
    }

    func testUnblockOfNonBlockedStatusesIsANoOp() throws {
        for current in [TaskStatus.toDo, .inProgress, .dropped, .done] {
            let task = try makeTask(status: current)
            XCTAssertEqual(
                StatusTransition.unblock(task.id, in: task),
                .transitioned([]),
                "unblocking from \(current.rawValue) changes nothing")
        }
    }

    func testNoAutoUnblockAnywhereExceptTheExplicitOperation() throws {
        let task = try makeTask(status: .blocked)

        // startSession refuses Blocked (manual unblock required) — no auto
        // transition out of Blocked on start:
        XCTAssertEqual(StatusTransition.startSession(of: task.id, in: task), .refused(.blocked))
        // drop keeps it Blocked→Dropped (allowed active status), never back
        // to To Do:
        XCTAssertEqual(StatusTransition.drop(task.id, in: task), .transitioned([task.id]))
        // Only unblock returns Blocked → To Do:
        XCTAssertEqual(StatusTransition.unblock(task.id, in: task), .transitioned([task.id]))
    }

    // MARK: - drop / restore

    func testDropIsAllowedFromEachActiveStatus() throws {
        for current in [TaskStatus.toDo, .inProgress, .blocked] {
            let task = try makeTask(status: current)
            XCTAssertEqual(
                StatusTransition.drop(task.id, in: task),
                .transitioned([task.id]),
                "drop from \(current.rawValue)")
            assertApply(task, changes: [task.id], to: .dropped, becomes: .dropped)
        }
    }

    func testDropFromDroppedIsNoOpAndFromDoneIsRefused() throws {
        // Documented edge decisions: already-dropped is an idempotent no-op;
        // finished work is not abandoned (pinned .alreadyDone vocabulary).
        let dropped = try makeTask(status: .dropped)
        let done = try makeTask(status: .done)

        XCTAssertEqual(StatusTransition.drop(dropped.id, in: dropped), .transitioned([]))
        XCTAssertEqual(StatusTransition.drop(done.id, in: done), .refused(.alreadyDone))
    }

    func testDropAddressesSubtaskAtDepth() throws {
        let leaf = makeSubtask(title: "Define Q4 objectives", status: .inProgress)
        let middle = makeSubtask(title: "Draft OKRs", children: [leaf])
        let task = try makeTask(subtasks: [middle])

        XCTAssertEqual(StatusTransition.drop(leaf.id, in: task), .transitioned([leaf.id]))
    }

    func testRestoreLandsOnToDoNeverInProgress() throws {
        let task = try makeTask(status: .dropped)

        XCTAssertEqual(StatusTransition.restore(task.id, in: task), .transitioned([task.id]))
        // The decided set is applied to To Do — restore never goes directly
        // to In Progress:
        let restored = task.applying(status: .toDo, to: [task.id])
        XCTAssertEqual(restored.status, .toDo)
        XCTAssertNotEqual(restored.status, .inProgress)
    }

    func testRestoreThenStartSessionReachesInProgress() throws {
        let task = try makeTask(status: .dropped)

        // Full pinned round trip: Dropped → (restore) → To Do → (start) →
        // In Progress. There is no Dropped → In Progress path.
        guard case .transitioned(let restored) = StatusTransition.restore(task.id, in: task)
        else {
            return XCTFail("expected .transitioned")
        }
        let restoredTree = task.applying(status: .toDo, to: restored)
        XCTAssertEqual(
            StatusTransition.startSession(of: task.id, in: restoredTree),
            .transitioned([task.id]))
    }

    func testRestoreOfNonDroppedStatusesIsANoOp() throws {
        for current in [TaskStatus.toDo, .inProgress, .blocked, .done] {
            let task = try makeTask(status: current)
            XCTAssertEqual(
                StatusTransition.restore(task.id, in: task),
                .transitioned([]),
                "restoring from \(current.rawValue) changes nothing")
        }
    }

    func testRestoreAddressesSubtaskAtDepth() throws {
        let leaf = makeSubtask(title: "Define Q4 objectives", status: .dropped)
        let middle = makeSubtask(title: "Draft OKRs", children: [leaf])
        let task = try makeTask(subtasks: [middle])

        XCTAssertEqual(StatusTransition.restore(leaf.id, in: task), .transitioned([leaf.id]))
    }

    // MARK: - Ad-hoc In-Progress start (PRD §8.6)

    func testAdHocTaskConstructedInProgressStartsAsAnAllowedNoOp() throws {
        // §8.6 decision (documented on StatusTransition): the timer flow
        // constructs the ad-hoc TaskItem with .inProgress and creates it via
        // the existing #7 create — no initialStatus parameter. startSession
        // on such a task is the pinned allowed no-op; the first session
        // proceeds on an In-Progress task.
        let adHoc = try TaskItem(
            title: "Ad-hoc from the timer",
            categories: [Category(name: "Work")],
            status: .inProgress
        )

        XCTAssertEqual(adHoc.status, .inProgress)
        XCTAssertEqual(StatusTransition.startSession(of: adHoc.id, in: adHoc), .transitioned([]))
    }

    // MARK: - Derived planning sets: Blocked/Dropped never included

    func testPlanningEligibleIDsExcludeBlockedDroppedAndDone() throws {
        let toDoSub = makeSubtask(title: "To-do sub")
        let inProgressSub = makeSubtask(title: "In-progress sub", status: .inProgress)
        let blockedSub = makeSubtask(title: "Blocked sub", status: .blocked)
        let droppedSub = makeSubtask(title: "Dropped sub", status: .dropped)
        let doneSub = makeSubtask(title: "Done sub", status: .done)
        let task = try makeTask(status: .inProgress, subtasks: [
            toDoSub, inProgressSub, blockedSub, droppedSub, doneSub,
        ])

        XCTAssertEqual(
            StatusTransition.planningEligibleIDs(in: task),
            [task.id, toDoSub.id, inProgressSub.id])
        XCTAssertFalse(StatusTransition.planningEligibleIDs(in: task).contains(blockedSub.id))
        XCTAssertFalse(StatusTransition.planningEligibleIDs(in: task).contains(droppedSub.id))
    }

    func testPlanningEligibleIDsAreNodeLevelByOwnStatus() throws {
        // Documented: exclusion is by the node's own status; whether a
        // Blocked ancestor also hides its descendants from recommendations is
        // Lifebot filtering (out of scope). A To Do child of a Blocked parent
        // stays eligible; a Blocked leaf of a plannable parent is excluded.
        var blockedParent = makeSubtask(title: "Blocked parent", status: .blocked)
        let childOfBlocked = makeSubtask(title: "Child of blocked")
        blockedParent.children = [childOfBlocked]
        let healthyParent = makeSubtask(title: "Healthy parent", children: [
            makeSubtask(title: "Blocked leaf", status: .blocked),
        ])
        let task = try makeTask(status: .toDo, subtasks: [blockedParent, healthyParent])

        XCTAssertEqual(
            StatusTransition.planningEligibleIDs(in: task),
            [task.id, childOfBlocked.id, healthyParent.id])
    }

    func testPlanningEligibilityExcludesDoneTreeNodesAtDepth() throws {
        let deepDone = makeSubtask(title: "Deep done", status: .done)
        let middle = makeSubtask(title: "Middle", status: .dropped, children: [deepDone])
        let task = try makeTask(subtasks: [middle])

        // Neither the Dropped middle nor its Done descendant is plannable.
        XCTAssertEqual(
            StatusTransition.planningEligibleIDs(in: task),
            [task.id])
    }

    // MARK: - Applying change sets (pure composition used by the wrapper)

    func testApplyingChangeSetIgnoresUnknownIDsAndPreservesTheRest() throws {
        let first = makeSubtask(title: "First")
        let second = makeSubtask(title: "Second", status: .inProgress)
        let task = try makeTask(status: .inProgress, subtasks: [first, second])

        let applied = task.applying(status: .done, to: [first.id, UUID()])

        XCTAssertEqual(applied.status, .inProgress, "the task itself was not in the set")
        XCTAssertEqual(applied.subtasks[0].status, .done)
        XCTAssertEqual(applied.subtasks[1].status, .inProgress, "unrelated nodes untouched")
        // Pure: the receiver is never mutated.
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.subtasks[0].status, .toDo)
    }

    func testApplyingChangeSetToDeeplyNestedIDs() throws {
        let leaf = makeSubtask(title: "Leaf")
        let middle = makeSubtask(title: "Middle", children: [leaf])
        let other = makeSubtask(title: "Other")
        let task = try makeTask(subtasks: [middle, other])

        let applied = task.applying(status: .done, to: [middle.id, leaf.id, task.id])

        XCTAssertEqual(applied.status, .done)
        XCTAssertEqual(applied.subtasks[0].status, .done)
        XCTAssertEqual(applied.subtasks[0].children[0].status, .done)
        XCTAssertEqual(applied.subtasks[1].status, .toDo)
    }
}
