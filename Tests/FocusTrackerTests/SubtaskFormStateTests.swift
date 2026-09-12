import XCTest
@testable import FocusTracker

/// Pure-logic tests for the #17 subtask form state (`SubtaskFormState` in
/// `Views/`): validation (title required, whitespace-only = empty), the
/// `SubtaskItem` ↔ form-state mapping with its round-trip guarantee (every
/// field, nil-vs-set for every optional), and the identity/tree preservation
/// of `makeSubtask(preserving:)` (the #8 editable surface: never constructs
/// id/children). No I/O anywhere — the type's pinned contract.
final class SubtaskFormStateTests: XCTestCase {

    // MARK: - Helpers

    private let deadline = DeadlineDay.date(from: "2026-12-24")

    /// A fully-populated subtask: every editable field set, one child (the
    /// subtree `makeSubtask(preserving:)` must carry through untouched).
    private func makeFullSubtask() -> SubtaskItem {
        SubtaskItem(
            id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!,
            title: "Draft objectives",
            status: .inProgress,
            priority: .medium,
            effort: .m,
            deadline: deadline,
            notes: "Two passes needed.",
            children: [
                SubtaskItem(
                    id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!,
                    title: "Nested child",
                    status: .blocked)
            ])
    }

    // MARK: - Blank defaults

    func testBlankFormDefaultsToToDoWithUnsetOptionals() {
        let state = SubtaskFormState()

        XCTAssertEqual(state.title, "")
        XCTAssertEqual(state.status, .toDo, "the default status is To Do (issue #17)")
        XCTAssertNil(state.priority)
        XCTAssertNil(state.effort)
        XCTAssertNil(state.deadline)
        XCTAssertNil(state.notes)
        XCTAssertFalse(state.isValid, "a blank form is not saveable")
    }

    // MARK: - Validation

    func testEmptyTitleIsInvalid() {
        var state = SubtaskFormState()
        state.status = .inProgress

        XCTAssertFalse(state.hasValidTitle)
        XCTAssertFalse(state.isValid, "empty title blocks save")
    }

    func testWhitespaceOnlyTitleIsInvalid() {
        for whitespace in ["   ", "\t", "\n \t "] {
            var state = SubtaskFormState()
            state.title = whitespace

            XCTAssertFalse(
                state.hasValidTitle, "whitespace-only (\(whitespace.debugDescription)) counts as empty")
            XCTAssertFalse(state.isValid)
        }
    }

    func testValidTitleMakesFormValid() {
        var state = SubtaskFormState()
        state.title = "  Outline the roadmap  "

        XCTAssertTrue(state.isValid)
    }

    // MARK: - Pre-fill mapping

    func testInitFromSubtaskCopiesEveryFieldVerbatim() {
        let subtask = makeFullSubtask()

        let state = SubtaskFormState(subtask: subtask)

        XCTAssertEqual(state.title, "Draft objectives")
        XCTAssertEqual(state.status, .inProgress)
        XCTAssertEqual(state.priority, .medium)
        XCTAssertEqual(state.effort, .m)
        XCTAssertEqual(state.deadline, deadline)
        XCTAssertEqual(state.notes, "Two passes needed.")
    }

    func testInitFromSubtaskWithNilOptionalsStaysNil() {
        let subtask = SubtaskItem(title: "Bare minimum")

        let state = SubtaskFormState(subtask: subtask)

        XCTAssertEqual(state.title, "Bare minimum")
        XCTAssertEqual(state.status, .toDo)
        XCTAssertNil(state.priority)
        XCTAssertNil(state.effort)
        XCTAssertNil(state.deadline)
        XCTAssertNil(state.notes)
    }

    // MARK: - Round trip (nil-vs-set, every optional)

    func testRoundTripWithEveryOptionalSetPreservesEverything() {
        let subtask = makeFullSubtask()

        let mapped = SubtaskFormState(subtask: subtask).makeSubtask(preserving: subtask)

        XCTAssertEqual(mapped, subtask, "item → state → item is the identity for clean input")
    }

    func testRoundTripWithEveryOptionalNilPreservesEverything() {
        let subtask = SubtaskItem(
            id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000003")!,
            title: "Bare minimum",
            status: .blocked)

        let mapped = SubtaskFormState(subtask: subtask).makeSubtask(preserving: subtask)

        XCTAssertEqual(mapped, subtask)
        XCTAssertNil(mapped.priority)
        XCTAssertNil(mapped.effort)
        XCTAssertNil(mapped.deadline)
        XCTAssertNil(mapped.notes)
    }

    /// For each optional field: setting it is preserved through the round
    /// trip and distinguishes from nil — the nil-vs-set distinction the
    /// mapping must not lose.
    func testNilVsSetIsPreservedForEachOptional() {
        func roundTrip(_ subtask: SubtaskItem) -> SubtaskItem {
            SubtaskFormState(subtask: subtask).makeSubtask(preserving: subtask)
        }

        // priority: nil vs set.
        XCTAssertNil(roundTrip(SubtaskItem(title: "T")).priority)
        XCTAssertEqual(roundTrip(SubtaskItem(title: "T", priority: .high)).priority, .high)
        // effort: nil vs set.
        XCTAssertNil(roundTrip(SubtaskItem(title: "T")).effort)
        XCTAssertEqual(roundTrip(SubtaskItem(title: "T", effort: .xl)).effort, .xl)
        // deadline: nil vs set.
        XCTAssertNil(roundTrip(SubtaskItem(title: "T")).deadline)
        XCTAssertEqual(
            roundTrip(SubtaskItem(title: "T", deadline: deadline)).deadline, deadline)
        // notes: nil vs set — and the empty string is a *set* value at the
        // mapping layer (the view maps "" to nil only in its own binding).
        XCTAssertNil(roundTrip(SubtaskItem(title: "T")).notes)
        XCTAssertEqual(roundTrip(SubtaskItem(title: "T", notes: "")).notes, "")
        XCTAssertEqual(roundTrip(SubtaskItem(title: "T", notes: "n")).notes, "n")
    }

    // MARK: - makeSubtask(preserving:)

    func testEditKeepsIDAndChildrenWhileEditingFields() {
        let original = makeFullSubtask()
        var state = SubtaskFormState(subtask: original)
        state.title = "Renamed objectives"
        state.status = .done
        state.priority = .high
        state.effort = .l
        state.deadline = DeadlineDay.date(from: "2027-01-02")
        state.notes = "Edited."

        let mapped = state.makeSubtask(preserving: original)

        XCTAssertEqual(mapped.id, original.id, "the ID addresses the edit — never edited")
        XCTAssertEqual(mapped.children, original.children, "the subtree is preserved verbatim")
        XCTAssertEqual(mapped.title, "Renamed objectives")
        XCTAssertEqual(mapped.status, .done)
        XCTAssertEqual(mapped.priority, .high)
        XCTAssertEqual(mapped.effort, .l)
        XCTAssertEqual(mapped.deadline, DeadlineDay.date(from: "2027-01-02"))
        XCTAssertEqual(mapped.notes, "Edited.")
    }

    func testCreateAssignsFreshIDWithNoChildrenAndTrimsTitle() {
        var state = SubtaskFormState()
        state.title = "  New subtask  "

        let mapped = state.makeSubtask(preserving: nil)

        XCTAssertNotEqual(mapped.id, UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        XCTAssertEqual(mapped.title, "New subtask", "the title is trimmed on save")
        XCTAssertEqual(mapped.status, .toDo)
        XCTAssertTrue(mapped.children.isEmpty, "create never constructs children")
    }
}
