import Foundation

/// The pure status-transition core (issue #9, PRD §6.5, §8.6, §12.1).
///
/// **Location decision (engineer's choice, documented):** this lives in a new
/// `Domain/` folder rather than `Models/`. The §6.5 status rules are a
/// cross-cutting domain concern: they are decided over a whole task tree
/// (the top-level task *and* its recursively nested subtasks, which #3's
/// `TaskItem.newlyDoneIDs(markingDone:)` already treats as one unit), they are
/// consumed by flows outside the model and the store (the timer flow #19 and
/// the planning-set semantics Lifebot builds on), and they are deliberately
/// independent of persistence. Precedent check: #3 kept pure completion logic
/// on the model (`Models/TaskCompletion.swift`), and #8 kept pure tree helpers
/// in `Vault/` because they encode *store-side persistence semantics* — the
/// transition decisions here are neither, so `Domain/` is the honest home.
///
/// **Shape:** five decision functions over one task tree — `startSession`,
/// `complete`, `unblock`, `drop`, `restore` — plus the derived planning-set
/// state rule (`planningEligibleIDs(in:)`). Everything is pure: no file I/O,
/// no isolation, no global state, no throwing, no crashes. Each function maps
/// (tree, target ID) → a typed, `Equatable` `Outcome`.
///
/// **Refusal contract (pinned, issue #9):** refusals are typed values carrying
/// the reason (`blocked`, `dropped`, `alreadyDone`) — never thrown errors and
/// never silent no-ops. Allowed transitions return the exact set of IDs whose
/// status changes; an empty set is a *legitimate* no-op (e.g. starting a
/// session on an In-Progress task). An unknown ID is its own typed outcome —
/// never an empty set masquerading as a no-op.
///
/// **Reuse of #3:** `complete` is a thin decision over the existing
/// `TaskItem.newlyDoneIDs(markingDone:)`, reused unchanged — no `Models/`
/// edits were needed for this issue. That function already encodes recursive
/// parent completion (bubbling through any nesting depth, never re-reporting
/// already-Done ancestors, empty for already-Done targets and unknown IDs),
/// and its "all children Done" check correctly holds a parent open while any
/// sibling is `To Do`, `In Progress`, or `Blocked`.
///
/// **Ad-hoc task start (§8.6, decision documented):** an ad-hoc task created
/// from the timer begins directly `In Progress` via *caller-side
/// construction*: `TaskItem` already takes a `status:` parameter, so the
/// timer (#19) constructs the item with `.inProgress` and creates it through
/// the existing #7 `VaultStore.create(_:)` — the status persists through the
/// codec like any other. No `initialStatus` parameter is added on top; a
/// second creation path would duplicate the #7 create contract for no gain.
/// (`startSession` on such a task is then the pinned allowed no-op.)
public enum StatusTransition {

    /// Why a transition was refused (pinned vocabulary, issue #9).
    public enum Refusal: Equatable, Sendable {
        /// The target is `Blocked`: it must be manually unblocked first.
        case blocked
        /// The target is `Dropped`: only a manual `restore` brings it back.
        case dropped
        /// The target is already `Done`: nothing to work on.
        case alreadyDone
    }

    /// The typed outcome of a transition decision (pinned contract, issue #9).
    public enum Outcome: Equatable, Sendable {
        /// Allowed. Carries the exact set of IDs whose status changes — an
        /// empty set is a legitimate no-op, not a refusal.
        case transitioned(Set<UUID>)
        /// Refused; the reason is carried, nothing changes.
        case refused(Refusal)
        /// The ID does not exist in the tree. A distinct typed outcome —
        /// never a crash, never a silent empty set.
        case unknownID(UUID)
    }

    // MARK: - Decisions (PRD §6.5)

    /// Decides `startSession(taskOrSubtaskID:)` — called by the timer flow
    /// (#19) before starting a timer:
    ///
    /// - `To Do` → allowed, moves to `In Progress` (reports the transition);
    /// - `In Progress` → allowed no-op (empty set; the session proceeds);
    /// - `Blocked` → refused `.blocked` (manual unblock required first);
    /// - `Dropped` → refused `.dropped` (manual restore only);
    /// - `Done` → refused `.alreadyDone` (nothing to work on).
    public static func startSession(of id: UUID, in tree: TaskItem) -> Outcome {
        guard let current = status(of: id, in: tree) else { return .unknownID(id) }
        switch current {
        case .toDo:
            return .transitioned([id])
        case .inProgress:
            return .transitioned([])
        case .blocked:
            return .refused(.blocked)
        case .dropped:
            return .refused(.dropped)
        case .done:
            return .refused(.alreadyDone)
        }
    }

    /// Decides `complete(taskOrSubtaskID:)` — the target becomes `Done` and
    /// recursive parent completion bubbles upward: every ancestor whose
    /// children are all `Done` becomes `Done` in the same derived change set
    /// (reusing #3's `newlyDoneIDs(markingDone:)` unchanged). Because subtasks
    /// live inside their parent file, the whole set is at most one file
    /// rewrite (the owning top-level task's file — enforced by the store
    /// wrapper, which applies the set in one update).
    ///
    /// Completion is decided from *any* current status: the §6.5 completion
    /// rule ("Completed task: Yes" at session end) has no pinned refusal, and
    /// finishing a Blocked/Dropped node's work is a legitimate end-of-session
    /// outcome. An already-`Done` target yields the empty set (a legitimate
    /// no-op — re-completing changes nothing); an unknown ID is `.unknownID`.
    public static func complete(_ id: UUID, in tree: TaskItem) -> Outcome {
        guard id == tree.id || tree.chain(to: id) != nil else { return .unknownID(id) }
        return .transitioned(tree.newlyDoneIDs(markingDone: id))
    }

    /// Decides `unblock(taskOrSubtaskID:)` — `Blocked` → `To Do`, only via
    /// this explicit operation. No other decision function returns a `Blocked`
    /// node to `To Do` (no auto-unblock on start, no cascade): `startSession`
    /// refuses Blocked outright, and only `complete` may move a Blocked node
    /// onward (to `Done`, per the mixed-sibling completion rule).
    ///
    /// Unblocking a node that is not `Blocked` changes nothing — the empty set
    /// (an idempotent no-op, not a refusal: the pinned refusal vocabulary has
    /// no "not blocked" reason, and the pinned contract reserves the empty set
    /// for legitimate no-ops).
    public static func unblock(_ id: UUID, in tree: TaskItem) -> Outcome {
        guard let current = status(of: id, in: tree) else { return .unknownID(id) }
        return current == .blocked ? .transitioned([id]) : .transitioned([])
    }

    /// Decides `drop(taskOrSubtaskID:)` — any active status (`To Do`,
    /// `In Progress`, `Blocked`) → `Dropped`, always allowed.
    ///
    /// Documented edge decisions (not pinned by §6.5): dropping an already
    /// `Dropped` node is the empty set (idempotent no-op); dropping a `Done`
    /// node is refused `.alreadyDone` — finished work is not abandoned, and
    /// the pinned refusal vocabulary carries exactly that reason.
    public static func drop(_ id: UUID, in tree: TaskItem) -> Outcome {
        guard let current = status(of: id, in: tree) else { return .unknownID(id) }
        switch current {
        case .toDo, .inProgress, .blocked:
            return .transitioned([id])
        case .dropped:
            return .transitioned([])
        case .done:
            return .refused(.alreadyDone)
        }
    }

    /// Decides `restore(taskOrSubtaskID:)` — `Dropped` → `To Do`, **never
    /// directly `In Progress`**: the changed set is applied to `To Do` (the
    /// store wrapper writes `.toDo`; compose with
    /// `TaskItem.applying(status:to:)` in pure tests), and a subsequent
    /// `startSession` is what may move it to `In Progress`.
    ///
    /// Restoring a node that is not `Dropped` changes nothing — the empty set
    /// (idempotent no-op, same reasoning as `unblock`).
    public static func restore(_ id: UUID, in tree: TaskItem) -> Outcome {
        guard let current = status(of: id, in: tree) else { return .unknownID(id) }
        return current == .dropped ? .transitioned([id]) : .transitioned([])
    }

    // MARK: - Derived planning-set state rule (PRD §6.5)

    /// The IDs in this tree that may participate in derived planning sets:
    /// the task itself and every subtask at any depth whose own status is
    /// `To Do` or `In Progress`.
    ///
    /// **State rule (pinned here, issue #9):** `Blocked` and `Dropped` nodes
    /// are never part of derived planning sets (`Done` is finished work).
    /// Exclusion is by the node's own status; whether a Blocked/Dropped
    /// ancestor also hides its descendants from *recommendations* is a
    /// Lifebot filtering decision and explicitly out of scope (#15, #19) —
    /// only the state semantics live here.
    public static func planningEligibleIDs(in tree: TaskItem) -> Set<UUID> {
        var eligible: Set<UUID> = []
        if tree.status.isPlanningEligible {
            eligible.insert(tree.id)
        }
        collectPlanningEligibleIDs(in: tree.subtasks, into: &eligible)
        return eligible
    }

    private static func collectPlanningEligibleIDs(
        in subtasks: [SubtaskItem], into eligible: inout Set<UUID>
    ) {
        for subtask in subtasks {
            if subtask.status.isPlanningEligible {
                eligible.insert(subtask.id)
            }
            collectPlanningEligibleIDs(in: subtask.children, into: &eligible)
        }
    }

    // MARK: - Internals

    /// The target's current status, or nil when the ID is unknown (root or
    /// any-depth subtask — the same addressing rule as `VaultStore.lookup`).
    private static func status(of id: UUID, in tree: TaskItem) -> TaskStatus? {
        if id == tree.id { return tree.status }
        return tree.chain(to: id)?.last?.status
    }
}

extension TaskItem {
    /// A copy of this tree with `newStatus` applied to every ID in `ids` —
    /// the task itself and/or subtasks at any depth. Pure; unknown IDs are
    /// ignored. This is the composition the `VaultStore` wrapper uses to
    /// apply a multi-ID bubble-up change set to the parent tree in **one**
    /// whole-file rewrite; pure tests use it to assert post-decision state
    /// (e.g. `restore` lands on `To Do`, never `In Progress`).
    public func applying(status newStatus: TaskStatus, to ids: Set<UUID>) -> TaskItem {
        var copy = self
        if ids.contains(copy.id) {
            copy.status = newStatus
        }
        copy.subtasks = copy.subtasks.applying(status: newStatus, to: ids)
        return copy
    }
}

extension TaskStatus {
    /// Whether a node in this status may participate in derived planning sets
    /// (PRD §6.5, issue #9): `Blocked` and `Dropped` are excluded by the
    /// pinned state rule; `Done` is finished work.
    public var isPlanningEligible: Bool {
        self == .toDo || self == .inProgress
    }
}

extension Array where Element == SubtaskItem {
    /// Sibling-list half of `TaskItem.applying(status:to:)` — a copy of this
    /// list with `newStatus` applied to every listed ID, recursing through
    /// nested children at any depth. The receiver is never mutated.
    func applying(status newStatus: TaskStatus, to ids: Set<UUID>) -> [SubtaskItem] {
        var copy = self
        for index in copy.indices {
            if ids.contains(copy[index].id) {
                copy[index].status = newStatus
            }
            copy[index].children = copy[index].children.applying(
                status: newStatus, to: ids)
        }
        return copy
    }
}
