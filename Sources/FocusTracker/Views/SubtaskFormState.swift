import Foundation

/// The pure form state of the #17 create/edit subtask form: everything
/// `SubtaskFormView` edits, plus the `SubtaskItem` ↔ form-state mapping and
/// the validation rules. Mirrors the `TaskFormState` (#16) patterns; no I/O,
/// no SwiftUI — fully unit-testable (issue #17 "pure logic" criterion).
///
/// # No project/categories (pinned, PRD §5.4)
/// `SubtaskItem` carries no `project`/`categories` of its own — both resolve
/// from ancestors via the #3 `effectiveProject(of:)`/`effectiveCategories(of:)`
/// helpers — so the form state deliberately has no such fields either. The
/// form shows a note that both are inherited (see `SubtaskFormView`).
///
/// # Mapping contract
/// `init(subtask:)` copies fields verbatim (nothing normalized), and
/// `makeSubtask(preserving:)` carries the identity/tree fields the form does
/// not edit. Together they give the round-trip guarantee: `SubtaskItem` →
/// form state → `SubtaskItem` preserves every field, including nil-vs-set
/// optionals. The only sanitization — title whitespace trimming — is
/// deliberate, documented, and happens in `makeSubtask(preserving:)` (it
/// never affects `init(subtask:)`, so state→item→state holds for clean
/// input).
///
/// # What the mapping never touches (the #8 contract)
/// The form edits exactly title, status, priority, effort, deadline, notes —
/// the #8 `VaultStore.updateSubtask` editable surface. It never constructs
/// `id` (create assigns a fresh UUID via the model default; edit keeps the
/// original's — and the store re-asserts it anyway) and never constructs
/// `children` (tree shape is mutated only by add/delete/reorder; edit mode
/// preserves the original subtree verbatim through `preserving:`).
struct SubtaskFormState: Equatable, Sendable {

    // MARK: - Editable fields

    /// The raw title text (validated via `hasValidTitle`, trimmed on save).
    var title: String = ""
    /// The subtask status. Default `To Do`; all five statuses (§6.5) are
    /// selectable — same documented reading as #16 ("status required", not
    /// "status restricted").
    var status: TaskStatus = .toDo
    /// Priority (§6.6), or nil for none.
    var priority: Priority?
    /// Effort bucket (§6.7), or nil for none.
    var effort: Effort?
    /// Deadline (§6.8), or nil for none.
    var deadline: Date?
    /// Notes (§6 free text), or nil for none. Stored as `String?` so nil and
    /// set are distinct in the mapping; the view's editor binding maps the
    /// empty string to nil at the UI layer only (the #16 pattern), keeping
    /// the mapping itself lossless.
    var notes: String?

    // MARK: - Validation

    /// The title with surrounding whitespace removed — what `makeSubtask`
    /// saves.
    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title is required and non-empty; whitespace-only counts as empty
    /// (issue #17, mirroring #16).
    var hasValidTitle: Bool {
        !trimmedTitle.isEmpty
    }

    /// Whether the form can save: the title is the only required field (a
    /// subtask has no categories to satisfy).
    var isValid: Bool {
        hasValidTitle
    }

    // MARK: - Init

    /// A blank create form: empty title, `To Do`, all optionals unset.
    init() {}

    /// Pre-fills the edit form from `subtask` (issue #17 edit mode). Direct
    /// field copies — nothing is normalized — so the mapping round-trips
    /// (see the mapping contract above).
    init(subtask: SubtaskItem) {
        title = subtask.title
        status = subtask.status
        priority = subtask.priority
        effort = subtask.effort
        deadline = subtask.deadline
        notes = subtask.notes
    }

    // MARK: - Mapping form state → SubtaskItem

    /// Builds the subtask to persist.
    ///
    /// - Parameter preserving: The identity/tree fields the form does not
    ///   edit. `nil` (create mode) assigns a fresh UUID and no children —
    ///   `VaultStore.addSubtask` places the new node in the tree. A subtask
    ///   (edit mode) keeps its `id` and its whole `children` subtree: the
    ///   #8 contract is that a subtask edit touches only title/status/
    ///   priority/effort/deadline/notes, and the store additionally
    ///   re-asserts `id` and discards `children` edits on its side.
    /// - The title is trimmed (leading/trailing whitespace dropped;
    ///   whitespace-only is already rejected by `hasValidTitle`).
    func makeSubtask(preserving original: SubtaskItem?) -> SubtaskItem {
        SubtaskItem(
            id: original?.id ?? UUID(),
            title: trimmedTitle,
            status: status,
            priority: priority,
            effort: effort,
            deadline: deadline,
            notes: notes,
            children: original?.children ?? [])
    }
}
