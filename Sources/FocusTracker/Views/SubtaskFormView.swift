import SwiftUI

/// What the subtask form sheet presents (issue #17): creating a new subtask
/// under a given parent (`toParentSubtaskID` nil for a task-level add, the
/// parent subtask's ID for a nested add — the #8 contract), or editing an
/// existing one pre-filled from its current `SubtaskItem`. `Identifiable`
/// for `.sheet(item:)` (a fresh ID per presentation, so the same subtask can
/// be re-opened after a cancel).
struct SubtaskFormRequest: Identifiable {
    enum Mode {
        /// Create: `parentTaskID` is the top-level task whose file the write
        /// lands in; `toParentSubtaskID` is nil for a task-level add or the
        /// parent subtask's ID for a nested add (any depth — #8).
        case create(parentTaskID: UUID, toParentSubtaskID: UUID?)
        /// Edit: the subtask is pre-filled and its `id`/`children` preserved
        /// (see `SubtaskFormState.makeSubtask(preserving:)`).
        case edit(parentTaskID: UUID, subtask: SubtaskItem)
    }

    let id = UUID()
    let mode: Mode
}

/// The create/edit subtask form (issue #17, PRD §5.4, §20.2): one sheet
/// capturing the simplified subtask field set — title (required), status
/// (all five, default `To Do`), priority, effort, deadline, notes —
/// persisting through `AppModel` → `VaultStore` (#8). **No project/categories
/// fields** (pinned, PRD §5.4: subtasks inherit both from ancestors); the
/// form says so. The form never touches the filesystem directly (PRD §3.1,
/// §18).
///
/// # Presentation and keyboard (the #16 patterns, reused)
/// A **sheet** over the Tasks window (a half-completed form must survive
/// clicks elsewhere); Enter triggers the default (save) action — it only
/// closes the form when the form is valid — and Esc cancels. Validation
/// errors are shown inline next to their fields and block the save (the
/// form stays open); store errors surface inline too. On success the form
/// closes. Dark calm styling per the #15 `DesignTokens`.
struct SubtaskFormView: View {

    /// Create or edit (which subtask to pre-fill and preserve identity/tree
    /// fields from — see `SubtaskFormState.makeSubtask(preserving:)`).
    let request: SubtaskFormRequest
    /// Persists the built subtask (create or update — chosen by the caller
    /// from the mode) through `AppModel`. Thrown errors surface inline.
    let onSave: (SubtaskItem) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var state: SubtaskFormState
    @State private var hasDeadline: Bool
    @State private var deadlinePick: Date
    @State private var showValidationErrors = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    init(
        request: SubtaskFormRequest,
        onSave: @escaping (SubtaskItem) async throws -> Void
    ) {
        self.request = request
        self.onSave = onSave

        let initialState: SubtaskFormState
        switch request.mode {
        case .create: initialState = SubtaskFormState()
        case .edit(_, let subtask): initialState = SubtaskFormState(subtask: subtask)
        }
        _state = State(initialValue: initialState)
        _hasDeadline = State(initialValue: initialState.deadline != nil)
        _deadlinePick = State(
            initialValue: initialState.deadline ?? FormDeadline.canonical(from: .now))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(DesignTokens.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
                    titleField
                    statusField
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
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(modeTitle))
    }

    // MARK: - Chrome

    private var modeTitle: String {
        if case .edit = request.mode { return "Edit Subtask" }
        return "New Subtask"
    }

    private var header: some View {
        Text(modeTitle)
            .font(DesignTokens.sheetHeaderFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingM)
    }

    private var footer: some View {
        HStack {
            Text("Subtasks inherit the project and categories of their parent.")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
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
        if case .edit = request.mode { return "Save Changes" }
        return "Create Subtask"
    }

    // MARK: - Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Title")
                .font(DesignTokens.statusGroupFont)
            TextField("Subtask title", text: $state.title)
                .textFieldStyle(.roundedBorder)
            if showValidationErrors && !state.hasValidTitle {
                inlineError("A title is required (whitespace-only counts as empty).")
            }
        }
    }

    private var statusField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Status")
                .font(DesignTokens.statusGroupFont)
            // All five statuses selectable — including `Done` (same
            // documented reading as #16); default `To Do`.
            Picker("Status", selection: $state.status) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
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
                            let day = FormDeadline.canonical(from: .now)
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
                    state.deadline = FormDeadline.canonical(from: picked)
                }
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Notes")
                .font(DesignTokens.statusGroupFont)
            TextEditor(text: notesBinding)
                .font(DesignTokens.bodyFont)
                .frame(minHeight: DesignTokens.notesEditorMinHeight)
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.spacingXS)
                .background(DesignTokens.chipBackground)
                .cornerRadius(DesignTokens.cornerRadius)
        }
    }

    /// The editor binds to the *string* view of `state.notes`: the empty
    /// text means "no notes" (nil) — a UI-layer normalization only; the
    /// `SubtaskFormState` mapping itself stays lossless (the #16 pattern).
    private var notesBinding: Binding<String> {
        Binding(
            get: { state.notes ?? "" },
            set: { state.notes = $0.isEmpty ? nil : $0 })
    }

    // MARK: - Saving

    private func save() {
        guard !isSaving else { return }
        guard state.isValid else {
            showValidationErrors = true
            return
        }
        showValidationErrors = false
        saveErrorMessage = nil
        isSaving = true
        let original: SubtaskItem?
        if case .edit(_, let subtask) = request.mode { original = subtask } else { original = nil }
        let subtask = state.makeSubtask(preserving: original)
        Task {
            do {
                try await onSave(subtask)
                dismiss()
            } catch {
                // Store errors surface inline and keep the form open (the
                // #16 pattern) — the user's edits are never discarded.
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
        .font(DesignTokens.annotationFont)
    }
}
