import Foundation

extension TaskItem {
    /// Pure recursive-completion function (PRD §6.5, §7).
    ///
    /// Given this task tree, returns the set of IDs that become Done when the
    /// node with `id` is marked Done: the ID itself plus every ancestor whose
    /// children are all Done, bubbling upward through any nesting depth.
    /// Already-Done nodes are never re-reported; if the marked node is already
    /// Done (or the ID is unknown), the result is empty.
    public func newlyDoneIDs(markingDone id: UUID) -> Set<UUID> {
        if id == self.id {
            return status == .done ? [] : [id]
        }

        guard let chain = chain(to: id), let target = chain.last, target.status != .done else {
            return []
        }

        var newlyDone: Set<UUID> = [target.id]
        var nowDone: Set<UUID> = [target.id]

        for ancestor in chain.dropLast().reversed() {
            let allChildrenDone = ancestor.children.allSatisfy {
                nowDone.contains($0.id) || $0.status == .done
            }
            guard allChildrenDone else { break }
            if ancestor.status != .done {
                newlyDone.insert(ancestor.id)
            }
            nowDone.insert(ancestor.id)
        }

        if status != .done,
           subtasks.allSatisfy({ nowDone.contains($0.id) || $0.status == .done }) {
            newlyDone.insert(self.id)
        }

        return newlyDone
    }
}
