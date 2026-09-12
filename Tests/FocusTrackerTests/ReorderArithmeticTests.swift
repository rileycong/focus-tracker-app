import XCTest
@testable import FocusTracker

/// Tests for the #18 pure reorder arithmetic (`ReorderArithmetic`): the
/// destination-index → new-ordering derivation (top / bottom / middle /
/// same-index no-op; typed nils for unknown IDs and out-of-bounds indexes),
/// the keyboard swap derivations (typed no-op nil at list boundaries — never
/// a wrap-around), and the two guarantees the pinned pipeline rests on:
///
/// 1. Every helper output is an **exact permutation** of its input list, so
///    `TaskOrdering.reorder`'s and `reorderSubtasks`' permutation validation
///    never fires on UI-derived input — asserted exhaustively against both
///    validators.
/// 2. The generalized sibling-list variant (what subtask reorders use) is the
///    same arithmetic as the task-group variant — asserted by equivalence
///    with the #8 `[SubtaskItem]` list reordering.
final class ReorderArithmeticTests: XCTestCase {

    // MARK: - Fixtures

    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()
    private static let d = UUID()
    private static let e = UUID()

    private static var list: [UUID] { [a, b, c, d, e] }

    private func subtasks(ids: [UUID]) -> [SubtaskItem] {
        ids.map { SubtaskItem(id: $0, title: $0.uuidString) }
    }

    // MARK: - newOrder: destination index → new full ordering

    func testMoveToTopLandsAtIndexZero() throws {
        let newOrder = try XCTUnwrap(
            ReorderArithmetic.newOrder(moving: Self.d, to: 0, in: Self.list))
        XCTAssertEqual(newOrder, [Self.d, Self.a, Self.b, Self.c, Self.e])
    }

    func testMoveToBottomLandsAfterTheLastRow() throws {
        // Dropping onto the last row (index count-1) is the bottom move: the
        // moved ID is removed first, then inserted at the shortened list's
        // end.
        let newOrder = try XCTUnwrap(
            ReorderArithmetic.newOrder(moving: Self.a, to: 4, in: Self.list))
        XCTAssertEqual(newOrder, [Self.b, Self.c, Self.d, Self.e, Self.a])
    }

    func testMoveToMiddleLandsAtTheDestinationIndex() throws {
        // Moving up: the moved row takes exactly where the target row was.
        let up = try XCTUnwrap(
            ReorderArithmetic.newOrder(moving: Self.e, to: 1, in: Self.list))
        XCTAssertEqual(up, [Self.a, Self.e, Self.b, Self.c, Self.d])

        // Moving down: the moved row lands directly after the target row
        // (remove-then-insert at the current-order index).
        let down = try XCTUnwrap(
            ReorderArithmetic.newOrder(moving: Self.b, to: 3, in: Self.list))
        XCTAssertEqual(down, [Self.a, Self.c, Self.d, Self.b, Self.e])
    }

    func testMoveOntoOwnIndexIsIdenticalOrdering() throws {
        for index in Self.list.indices {
            let newOrder = try XCTUnwrap(
                ReorderArithmetic.newOrder(moving: Self.list[index], to: index, in: Self.list))
            XCTAssertEqual(
                newOrder, Self.list, "dropping onto its own row is a no-op, not nil")
        }
    }

    func testUnknownMovedIDIsTypedNil() throws {
        XCTAssertNil(
            ReorderArithmetic.newOrder(moving: UUID(), to: 0, in: Self.list))
    }

    func testOutOfBoundsDestinationIndexIsTypedNil() throws {
        XCTAssertNil(ReorderArithmetic.newOrder(moving: Self.a, to: -1, in: Self.list))
        XCTAssertNil(ReorderArithmetic.newOrder(moving: Self.a, to: 5, in: Self.list))
    }

    // MARK: - Swap derivations (keyboard move up/down)

    func testSwapUpExchangesWithPredecessor() throws {
        let newOrder = try XCTUnwrap(ReorderArithmetic.swapUp(Self.c, in: Self.list))
        XCTAssertEqual(newOrder, [Self.a, Self.c, Self.b, Self.d, Self.e])
    }

    func testSwapDownExchangesWithSuccessor() throws {
        let newOrder = try XCTUnwrap(ReorderArithmetic.swapDown(Self.c, in: Self.list))
        XCTAssertEqual(newOrder, [Self.a, Self.b, Self.d, Self.c, Self.e])
    }

    func testSwapUpAtTopIsTypedNilNeverWraps() {
        XCTAssertNil(ReorderArithmetic.swapUp(Self.a, in: Self.list))
    }

    func testSwapDownAtBottomIsTypedNilNeverWraps() {
        XCTAssertNil(ReorderArithmetic.swapDown(Self.e, in: Self.list))
    }

    func testSwapsOfUnknownIDAreTypedNil() {
        XCTAssertNil(ReorderArithmetic.swapUp(UUID(), in: Self.list))
        XCTAssertNil(ReorderArithmetic.swapDown(UUID(), in: Self.list))
    }

    func testSwapEqualsReorderToNeighborIndex() throws {
        // A keyboard swap is just a reorder whose destination index comes
        // from the neighbor (pinned, #18) — the derivations agree.
        for index in Self.list.indices {
            if index > 0 {
                XCTAssertEqual(
                    try XCTUnwrap(ReorderArithmetic.swapUp(Self.list[index], in: Self.list)),
                    try XCTUnwrap(
                        ReorderArithmetic.newOrder(
                            moving: Self.list[index], to: index - 1, in: Self.list)))
            }
            if index < Self.list.count - 1 {
                XCTAssertEqual(
                    try XCTUnwrap(ReorderArithmetic.swapDown(Self.list[index], in: Self.list)),
                    try XCTUnwrap(
                        ReorderArithmetic.newOrder(
                            moving: Self.list[index], to: index + 1, in: Self.list)))
            }
        }
    }

    // MARK: - Permutation guarantees (vs both store validators)

    func testNewOrderOutputIsAlwaysAnExactPermutationForTaskOrderingReorder() throws {
        // Exhaustive over (moved ID, destination index): `TaskOrdering.reorder`
        // — the #10 validator the task pipeline feeds — never fires
        // `reorderNotExactPermutation` on helper output.
        let list = Self.list
        let currentOrders = Dictionary(uniqueKeysWithValues: list.map { ($0, nil as Int?) })
        for moved in list {
            for destination in list.indices {
                let newOrder = try XCTUnwrap(
                    ReorderArithmetic.newOrder(moving: moved, to: destination, in: list))
                XCTAssertNoThrow(
                    try TaskOrdering.reorder(
                        currentDisplayOrder: list, newOrder: newOrder,
                        currentOrders: currentOrders),
                    "\(moved) → index \(destination) produced a non-permutation")
            }
        }
    }

    func testSwapOutputsAreAlwaysAnExactPermutationForTaskOrderingReorder() throws {
        let list = Self.list
        let currentOrders = Dictionary(uniqueKeysWithValues: list.map { ($0, nil as Int?) })
        for moved in list {
            for swap in [ReorderArithmetic.swapUp(moved, in: list),
                         ReorderArithmetic.swapDown(moved, in: list)] {
                guard let newOrder = swap else { continue }  // boundary no-ops
                XCTAssertNoThrow(
                    try TaskOrdering.reorder(
                        currentDisplayOrder: list, newOrder: newOrder,
                        currentOrders: currentOrders))
            }
        }
    }

    func testNewOrderOutputAlwaysSatisfiesTheSubtaskPermutationValidator() throws {
        // The subtask pipeline feeds `VaultStore.reorderSubtasks`, whose pure
        // core is `[SubtaskItem].reordered(to:)` — UI-derived sibling orders
        // must always pass its exact-permutation validation (#8 contract).
        let ids = Self.list
        let siblings = subtasks(ids: ids)
        for moved in ids {
            for destination in ids.indices {
                let newOrder = try XCTUnwrap(
                    ReorderArithmetic.newOrder(moving: moved, to: destination, in: ids))
                let reordered = try siblings.reordered(to: newOrder)
                XCTAssertEqual(reordered.map(\.id), newOrder)
            }
        }
    }

    func testSubtaskListVariantEquivalence() throws {
        // The generalized sibling-list variant is the same arithmetic the
        // task groups use — for an arbitrary (list, moved, destination)
        // triple the produced sibling order equals the #8 list reordering's
        // output order exactly.
        let ids = [Self.c, Self.a, Self.e, Self.b]
        let siblings = subtasks(ids: ids)
        let newOrder = try XCTUnwrap(
            ReorderArithmetic.newOrder(moving: Self.e, to: 0, in: ids))
        XCTAssertEqual(newOrder, [Self.e, Self.c, Self.a, Self.b])
        XCTAssertEqual(try siblings.reordered(to: newOrder).map(\.id), newOrder)

        let swapped = try XCTUnwrap(ReorderArithmetic.swapDown(Self.a, in: ids))
        XCTAssertEqual(swapped, [Self.c, Self.e, Self.a, Self.b])
        XCTAssertEqual(try siblings.reordered(to: swapped).map(\.id), swapped)
    }

    func testSubtreeTravelIsNotTheArithmeticConcernButTheListMoveIs() throws {
        // The moved subtask's nested subtree travels with it (#8 semantics) —
        // the arithmetic only permutes IDs; the store's `reordered(to:)`
        // carries the whole node. Assert the moved node's children arrive
        // intact at its new position.
        let child = SubtaskItem(id: UUID(), title: "child")
        let parent = SubtaskItem(id: Self.a, title: "parent", children: [child])
        let siblingB = SubtaskItem(id: Self.b, title: "b")
        let siblingD = SubtaskItem(id: Self.d, title: "d")
        let siblings = [siblingB, parent, siblingD]
        let newOrder = try XCTUnwrap(
            ReorderArithmetic.newOrder(moving: Self.a, to: 0, in: [Self.b, Self.a, Self.d]))
        let reordered = try siblings.reordered(to: newOrder)
        XCTAssertEqual(reordered.map(\.id), [Self.a, Self.b, Self.d])
        XCTAssertEqual(reordered[0].children.map(\.id), [child.id])
    }
}
