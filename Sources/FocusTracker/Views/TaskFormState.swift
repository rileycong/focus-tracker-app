import Foundation

/// The pure form state of the #16 create/edit task form: everything
/// `TaskFormView` edits, plus the `TaskItem` ↔ form-state mapping, the
/// validation rules and the inline-category commit logic. No I/O, no
/// SwiftUI — fully unit-testable (issue #16 "pure logic" criterion).
///
/// # Mapping contract
/// `init(task:)` copies fields verbatim (nothing normalized), and
/// `makeTask(preserving:)` carries identity/order fields the form does not
/// edit. Together they give the round-trip guarantee: form state →
/// `TaskItem` → form state preserves every field, including nil-vs-set
/// optionals. The only sanitizations — title/project whitespace trimming —
/// are deliberate, documented, and happen in `makeTask(preserving:)` (they
/// never affect `init(task:)`, so state→item→state holds for clean input).
///
/// # Validation (issue #16, PRD §6.3, §8.5)
/// - Title required; whitespace-only counts as empty.
/// - At least one category required (the model enforces the same invariant —
///   `TaskItem`'s throwing initializer — so an invalid state cannot persist).
struct TaskFormState: Equatable, Sendable {

    // MARK: - Editable fields

    /// The raw title text (validated via `hasValidTitle`, trimmed on save).
    var title: String = ""
    /// Committed category tokens (trimmed, non-empty, case-insensitively
    /// deduplicated — see `commitCategory(_:)`).
    var categoryNames: [String] = []
    /// The in-progress text of the category combobox field (Enter/comma
    /// commit — see `commitCompletedCategorySegments()` and
    /// `commitWholeDraft()`).
    var categoryDraft: String = ""
    /// The task status. Default `To Do`; all five statuses (§6.5) are
    /// selectable — including `Done` — because PRD §8.5 requires a status,
    /// it does not restrict which one (documented reading, issue #16).
    var status: TaskStatus = .toDo
    /// The project name, or nil for no project (§6.4: optional).
    var projectName: String?
    /// Priority (§6.6), or nil for none.
    var priority: Priority?
    /// Effort bucket (§6.7), or nil for none.
    var effort: Effort?
    /// Deadline (§6.8), or nil for none.
    var deadline: Date?
    /// Notes (§6 free text), or nil for none. Stored as `String?` so nil and
    /// set are distinct in the mapping; the view's editor binding maps the
    /// empty string to nil at the UI layer only (an empty editor means "no
    /// notes"), keeping the mapping itself lossless.
    var notes: String?

    // MARK: - Validation

    /// The title with surrounding whitespace removed — what `makeTask` saves.
    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title is required and non-empty; whitespace-only counts as empty
    /// (issue #16).
    var hasValidTitle: Bool {
        !trimmedTitle.isEmpty
    }

    /// At least one category is required (PRD §6.3).
    var hasValidCategories: Bool {
        !categoryNames.isEmpty
    }

    /// Whether the form can save: both required fields valid.
    var isValid: Bool {
        hasValidTitle && hasValidCategories
    }

    // MARK: - Init

    /// A blank create form: empty title, no categories, `To Do`, all
    /// optionals unset.
    init() {}

    /// Pre-fills the edit form from `task` (issue #16 edit mode). Direct
    /// field copies — nothing is normalized — so the mapping round-trips
    /// (see the mapping contract above).
    init(task: TaskItem) {
        title = task.title
        categoryNames = task.categories.map(\.name)
        status = task.status
        projectName = task.project?.name
        priority = task.priority
        effort = task.effort
        deadline = task.deadline
        notes = task.notes
    }

    // MARK: - Mapping form state → TaskItem

    /// Builds the task to persist.
    ///
    /// - Parameter preserving: The identity/order fields the form does not
    ///   edit. `nil` (create mode) assigns a fresh UUID, no manual order and
    ///   no subtasks. A task (edit mode) keeps its `id`, `order` and
    ///   `subtasks` — in particular **a title change does not move the file
    ///   on disk**: `VaultStore.update` resolves the filename through the
    ///   ID↔filename mapping and never re-derives it from the title (#7);
    ///   re-slugging is the separate `rename` API, which the form does not
    ///   call.
    /// - The title is trimmed (leading/trailing whitespace dropped;
    ///   whitespace-only is already rejected by `hasValidTitle`), and a
    ///   whitespace-only project name is treated as no project. Categories
    ///   must be non-empty — the throwing initializer surfaces
    ///   `TaskItem.ValidationError.atLeastOneCategoryRequired` when called on
    ///   an invalid state anyway (defense in depth; the form checks
    ///   `isValid` first).
    func makeTask(preserving original: TaskItem?) throws -> TaskItem {
        var project: Project?
        if let name = projectName?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        {
            project = Project(name: name)
        }
        return try TaskItem(
            id: original?.id ?? UUID(),
            title: trimmedTitle,
            categories: categoryNames.map(Category.init(name:)),
            status: status,
            project: project,
            priority: priority,
            effort: effort,
            deadline: deadline,
            notes: notes,
            order: original?.order,
            subtasks: original?.subtasks ?? [])
    }

    // MARK: - Inline category handling (issue #16, PRD §6.3)

    /// Normalizes a raw draft segment: whitespace-trimmed; nil when nothing
    /// remains — a whitespace-only draft never creates a token.
    static func normalizedCategory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `name` is already a committed token, compared
    /// case-insensitively (categories are free-form user labels; "work" and
    /// "Work" are the same label in practice — documented choice).
    func containsCategory(named name: String) -> Bool {
        categoryNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Commits `raw` as a category token when it normalizes to a non-empty
    /// name that is not already committed. Returns whether a token was added;
    /// the caller clears the draft when it committed something.
    @discardableResult
    mutating func commitCategory(_ raw: String) -> Bool {
        guard let name = Self.normalizedCategory(raw),
            !containsCategory(named: name)
        else { return false }
        categoryNames.append(name)
        return true
    }

    /// The combobox's comma behavior: complete comma-separated segments of
    /// the draft are committed and removed; the trailing segment (no comma
    /// after it) stays in the field while the user keeps typing (trimmed —
    /// it is committed through the same normalizing path later). Empty
    /// segments (double commas, trailing commas) are dropped silently.
    mutating func commitCompletedCategorySegments() {
        guard categoryDraft.contains(",") else { return }
        var parts = categoryDraft.components(separatedBy: ",")
        let trailing = parts.removeLast()
        for part in parts where commitCategory(part) {}
        categoryDraft = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enter in the category field: commits the whole draft as one token and
    /// always clears the field. Returns whether a token was added — a
    /// whitespace-only draft adds nothing (dropped), a duplicate name adds
    /// nothing but still clears (the token is already there).
    @discardableResult
    mutating func commitWholeDraft() -> Bool {
        defer { categoryDraft = "" }
        return commitCategory(categoryDraft)
    }

    /// Removes the committed token `name` (the chip's delete button).
    mutating func removeCategory(_ name: String) {
        categoryNames.removeAll { $0 == name }
    }

    // MARK: - Inventory gathering (the combobox's suggestion lists)

    /// All distinct category names across `tasks` — case-insensitively
    /// deduplicated, sorted case-insensitively — for the category
    /// combobox's suggestion list (issue #16).
    static func knownCategoryNames(in tasks: [TaskItem]) -> [String] {
        var names: [String] = []
        for task in tasks {
            for category in task.categories
            where !names.contains(where: {
                $0.caseInsensitiveCompare(category.name) == .orderedSame
            }) {
                names.append(category.name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// All distinct project names across `tasks`, sorted
    /// case-insensitively — for the project picker's existing-projects list
    /// (issue #16).
    static func knownProjectNames(in tasks: [TaskItem]) -> [String] {
        var names: [String] = []
        for task in tasks {
            if let name = task.project?.name,
                !names.contains(name)
            {
                names.append(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
