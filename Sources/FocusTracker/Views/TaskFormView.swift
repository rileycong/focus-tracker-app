import SwiftUI

/// What the task form sheet presents (issue #16): creating a new task, or
/// editing an existing one pre-filled from its current `TaskItem`.
/// `Identifiable` for `.sheet(item:)` (a fresh ID per presentation, so the
/// same task can be re-opened after a cancel).
struct TaskFormRequest: Identifiable {
    enum Mode {
        case create
        case edit(TaskItem)
    }

    let id = UUID()
    let mode: Mode
}

/// The create/edit task form (issue #16, PRD §6, §8.5): one sheet capturing
/// every top-level task field — title, categories (token field with inline
/// creation from the inventory + free typing), status (all five, default
/// `To Do`), project (picker of existing + free-text new), priority, effort,
/// deadline and notes — persisting through `AppModel` → `VaultStore` (#7).
/// The form never touches the filesystem directly (PRD §3.1, §18).
///
/// # Presentation (documented choice)
/// A **sheet** over the Tasks window: a half-completed form must survive
/// clicks elsewhere, which rules out a popover (popovers dismiss on any
/// outside interaction and would silently discard the user's edits); the
/// dimmed inventory stays visible behind the sheet for context.
///
/// # Entry points (documented choice)
/// - **Create:** the Tasks-view toolbar "New Task" button (⌘N) and the
///   "New Task…" row context menu.
/// - **Edit:** the toolbar "Edit" button (⌘E, enabled while a task is
///   selected) and the "Edit Task…" row context menu. Double-click is
///   deliberately not wired: a single click already toggles row selection
///   (#15), and layering a double-click gesture on top makes both harder to
///   use; selection-then-Edit is unambiguous.
///
/// # Documented readings/behaviors
/// - **Status:** all five statuses (§6.5) are selectable — including `Done` —
///   because PRD §8.5 says "status required", not "status restricted"; the
///   default for a new task is `To Do`.
/// - **Title change (edit mode):** only the display title changes — the
///   file on disk keeps its name, by design (#7 `update` never re-derives
///   the filename from the title; re-slugging is the separate `rename` API,
///   which this form does not call). A caption in the form says so.
/// - **Inline categories (§6.3):** typing a new name and pressing Enter or
///   a comma creates a token; whitespace-only input creates nothing;
///   duplicates (case-insensitive) are not added twice. A pending draft is
///   committed on save so a half-typed category is not lost.
/// - **Project (§6.4):** the picker's choice — an existing project, a typed
///   new-project name, or None — flows into the form state as it changes
///   (`applyProjectChoice`) and again at save time, so it always reaches
///   the saved task in both create and edit modes; None clears the project
///   (nil, not an empty string).
/// - **Keyboard:** Enter triggers the default (save) action — it only
///   closes the form when the form is valid; Esc cancels.
/// - Validation errors are shown inline next to their fields and block the
///   save (the form stays open); store errors surface inline too. On
///   success the form closes.
struct TaskFormView: View {

    /// Create or edit (which task to pre-fill and preserve identity fields
    /// from — see `TaskFormState.makeTask(preserving:)`).
    let mode: TaskFormRequest.Mode
    /// Distinct category names across the current inventory (the combobox's
    /// suggestion list).
    let knownCategoryNames: [String]
    /// Distinct project names across the current inventory (the project
    /// picker's existing entries).
    let knownProjectNames: [String]
    /// Persists the built task (create or update — chosen by the caller from
    /// the mode) through `AppModel`. Thrown errors surface inline.
    let onSave: (TaskItem) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var state: TaskFormState
    @State private var hasDeadline: Bool
    @State private var deadlinePick: Date
    @State private var projectChoice: ProjectChoice
    @State private var newProjectName = ""
    @State private var showValidationErrors = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    /// The project picker's selection shape (issue #16: optional project —
    /// existing projects from the inventory + free-text entry for a new
    /// one); defined on `TaskFormState`, which owns the choice → state
    /// wiring (`applyProjectChoice`).
    private typealias ProjectChoice = TaskFormState.ProjectChoice

    init(
        mode: TaskFormRequest.Mode,
        knownCategoryNames: [String],
        knownProjectNames: [String],
        onSave: @escaping (TaskItem) async throws -> Void
    ) {
        self.mode = mode
        self.knownCategoryNames = knownCategoryNames
        self.knownProjectNames = knownProjectNames
        self.onSave = onSave

        let initialState: TaskFormState
        switch mode {
        case .create: initialState = TaskFormState()
        case .edit(let task): initialState = TaskFormState(task: task)
        }
        _state = State(initialValue: initialState)
        _hasDeadline = State(initialValue: initialState.deadline != nil)
        _deadlinePick = State(
            initialValue: initialState.deadline ?? Self.canonicalDeadline(from: .now))
        _projectChoice = State(
            initialValue: initialState.projectName.map(ProjectChoice.existing) ?? .none)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(DesignTokens.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
                    titleField
                    categoriesField
                    statusField
                    projectField
                    priorityAndEffortField
                    deadlineField
                    notesField
                    if let saveErrorMessage {
                        inlineError(saveErrorMessage)
                    }
                }
                .padding(DesignTokens.spacingL)
            }
            Divider()
                .overlay(DesignTokens.divider)
            footer
        }
        .background(DesignTokens.background)
        .frame(width: 470)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(modeTitle))
    }

    // MARK: - Chrome

    private var modeTitle: String {
        if case .edit = mode { return "Edit Task" }
        return "New Task"
    }

    private var header: some View {
        Text(modeTitle)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingM)
    }

    private var footer: some View {
        HStack {
            if case .edit = mode {
                Text("Changing the title does not rename the task's file on disk.")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(saveButtonTitle, action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, DesignTokens.spacingM)
    }

    private var saveButtonTitle: String {
        if case .edit = mode { return "Save Changes" }
        return "Create Task"
    }

    // MARK: - Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Title")
                .font(DesignTokens.statusGroupFont)
            TextField("Task title", text: $state.title)
                .textFieldStyle(.roundedBorder)
            if showValidationErrors && !state.hasValidTitle {
                inlineError("A title is required (whitespace-only counts as empty).")
            }
        }
    }

    private var categoriesField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Categories")
                .font(DesignTokens.statusGroupFont)
            HStack(spacing: DesignTokens.spacingS) {
                TextField("Add a category…", text: $state.categoryDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.commitWholeDraft() }
                    .onChange(of: state.categoryDraft) { _, draft in
                        if draft.contains(",") { state.commitCompletedCategorySegments() }
                    }
                if !categorySuggestions.isEmpty {
                    Menu {
                        ForEach(categorySuggestions, id: \.self) { name in
                            Button(name) { state.commitCategory(name) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Existing categories")
                }
            }
            if !state.categoryNames.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)],
                    alignment: .leading,
                    spacing: DesignTokens.spacingXS
                ) {
                    ForEach(state.categoryNames, id: \.self) { name in
                        categoryToken(name)
                    }
                }
            }
            if showValidationErrors && !state.hasValidCategories {
                inlineError("Add at least one category.")
            }
        }
    }

    private func categoryToken(_ name: String) -> some View {
        HStack(spacing: DesignTokens.spacingXS) {
            Text(name)
                .font(DesignTokens.chipFont)
                .lineLimit(1)
            Button {
                state.removeCategory(name)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove category")
        }
        .padding(.horizontal, DesignTokens.spacingS)
        .padding(.vertical, DesignTokens.spacingXS)
        .background(DesignTokens.chipBackground)
        .cornerRadius(DesignTokens.cornerRadius)
    }

    /// Existing inventory categories not already committed as tokens.
    private var categorySuggestions: [String] {
        knownCategoryNames.filter { !state.containsCategory(named: $0) }
    }

    private var statusField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Status")
                .font(DesignTokens.statusGroupFont)
            // All five statuses selectable — including `Done` (§8.5 says
            // "status required", not "status restricted"); default `To Do`.
            Picker("Status", selection: $state.status) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var projectField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Project")
                .font(DesignTokens.statusGroupFont)
            Picker("Project", selection: $projectChoice) {
                Text("None").tag(ProjectChoice.none)
                ForEach(projectOptions, id: \.self) { name in
                    Text(name).tag(ProjectChoice.existing(name))
                }
                Divider()
                Text("New Project…").tag(ProjectChoice.new)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: projectChoice) { _, choice in
                // The picker's choice lands in the form state as it
                // changes, so the picked project is never silently
                // dropped and a stale one never persists (issue #16).
                state.applyProjectChoice(choice, newProjectName: newProjectName)
            }
            if projectChoice == .new {
                TextField("New project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: newProjectName) { _, name in
                        // The typed new-project name flows into the state
                        // as it is typed (issue #16).
                        state.applyProjectChoice(.new, newProjectName: name)
                    }
            }
        }
    }

    /// Existing projects, plus the edited task's current project when it is
    /// no longer among the inventory's names (so the picker can display it).
    private var projectOptions: [String] {
        if case .existing(let current) = projectChoice,
            !knownProjectNames.contains(current)
        {
            return knownProjectNames + [current]
        }
        return knownProjectNames
    }

    private var priorityAndEffortField: some View {
        HStack(alignment: .top, spacing: DesignTokens.spacingL) {
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                Text("Priority")
                    .font(DesignTokens.statusGroupFont)
                Picker("Priority", selection: $state.priority) {
                    Text("None").tag(Priority?.none)
                    ForEach(Priority.allCases, id: \.self) { priority in
                        Text(priority.rawValue).tag(Priority?.some(priority))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                Text("Effort")
                    .font(DesignTokens.statusGroupFont)
                Picker("Effort", selection: $state.effort) {
                    Text("None").tag(Effort?.none)
                    ForEach(Effort.allCases, id: \.self) { effort in
                        Text(effort.rawValue).tag(Effort?.some(effort))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            Spacer()
        }
    }

    private var deadlineField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Toggle("Deadline", isOn: $hasDeadline)
                .font(DesignTokens.statusGroupFont)
                .onChange(of: hasDeadline) { _, isOn in
                    if isOn {
                        if state.deadline == nil {
                            let day = Self.canonicalDeadline(from: .now)
                            deadlinePick = day
                            state.deadline = day
                        }
                    } else {
                        state.deadline = nil
                    }
                }
            DatePicker(
                "Deadline", selection: $deadlinePick,
                displayedComponents: [.date])
                .labelsHidden()
                .disabled(!hasDeadline)
                .onChange(of: deadlinePick) { _, picked in
                    state.deadline = Self.canonicalDeadline(from: picked)
                }
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Notes")
                .font(DesignTokens.statusGroupFont)
            TextEditor(text: notesBinding)
                .font(.body)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.spacingXS)
                .background(DesignTokens.chipBackground)
                .cornerRadius(DesignTokens.cornerRadius)
        }
    }

    /// The editor binds to the *string* view of `state.notes`: the empty
    /// text means "no notes" (nil) — a UI-layer normalization only; the
    /// `TaskFormState` mapping itself stays lossless.
    private var notesBinding: Binding<String> {
        Binding(
            get: { state.notes ?? "" },
            set: { state.notes = $0.isEmpty ? nil : $0 })
    }

    // MARK: - Saving

    private func save() {
        guard !isSaving else { return }
        // A pending category draft commits on save so a half-typed name is
        // not silently lost (documented).
        state.commitWholeDraft()
        // The project picker's current choice lands in the state here too —
        // the onChange handlers keep it in sync live; this is the save-time
        // guarantee that the chosen project (existing, new, or None)
        // reaches the saved task in both create and edit modes (issue #16).
        state.applyProjectChoice(projectChoice, newProjectName: newProjectName)
        guard state.isValid else {
            showValidationErrors = true
            return
        }
        showValidationErrors = false
        saveErrorMessage = nil
        isSaving = true
        let original: TaskItem?
        if case .edit(let task) = mode { original = task } else { original = nil }
        let task: TaskItem
        do {
            task = try state.makeTask(preserving: original)
        } catch {
            // The model enforces ≥1 category; an invalid state cannot reach
            // here through the guarded flow — surfaced as validation errors.
            showValidationErrors = true
            isSaving = false
            return
        }
        Task {
            do {
                try await onSave(task)
                dismiss()
            } catch {
                saveErrorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    // MARK: - Small building blocks

    private func inlineError(_ message: String) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(DesignTokens.overdue)
        }
        .font(.caption)
    }

    /// The picked local calendar day in the #4 canonical deadline shape
    /// (noon UTC on that day), so the persisted `yyyy-MM-dd` is exactly the
    /// day the user picked for any |UTC offset| ≤ 12 h — the same WYSIWYG
    /// convention `DeadlineDay` uses for parsing.
    private static func canonicalDeadline(from picked: Date) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let day = local.dateComponents([.year, .month, .day], from: picked)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return (utc.date(from: day) ?? picked).addingTimeInterval(12 * 60 * 60)
    }
}
