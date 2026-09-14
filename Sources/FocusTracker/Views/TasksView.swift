import SwiftUI
import UniformTypeIdentifiers

/// The app's default view (issue #15, PRD §8.2): the read-only task inventory
/// grouped per PRD §8.3, driven by the #14 composition root. Rendering and
/// sub-structure live in the `Views/` group; this type wires the observable
/// state — `AppModel.vaultState` decides the app state (onboarding, degraded
/// banner, loaded), and `AppModel.tasks` is mirrored into the
/// `TasksViewModel` whose sections/selection the list renders.
struct TasksView: View {
    private let model: AppModel
    @State private var viewModel: TasksViewModel
    /// The #16 form presentation: nil = closed; non-nil shows the sheet
    /// (create, or edit of a specific task).
    @State private var formRequest: TaskFormRequest?
    /// The #17 subtask form presentation: nil = closed; non-nil shows the
    /// sheet (a create under a given parent, or the edit of a subtask).
    @State private var subtaskFormRequest: SubtaskFormRequest?
    /// The #19 session-start sheet presentation: nil = closed; non-nil
    /// shows the sheet, pre-selecting the row it was opened from — or,
    /// with no row hand-off, the #34 last-session target (composed at
    /// the sheet call below; eligibility is filtered by the sheet).
    @State private var sessionStartRequest: SessionStartRequest?
    /// The #17 delete path's error surface: the subtask confirmation dialog
    /// has no form to surface a store error inline, so a failed delete is
    /// reported here (the inventory is untouched on failure — nothing is
    /// silently lost, PRD §18).
    @State private var deleteErrorMessage: String?
    /// The #18 reorder error surface: any `reorderTasks`/`reorderSubtasks`
    /// failure — `.vaultChangedExternally`, `.orderingBatchIncomplete`,
    /// `.reorderNotExactPermutation`, `.writeFailed`, `.noVaultConfigured`, …
    /// — surfaces here as a non-blocking alert (consistent with the #17
    /// delete-error surface) with a Reload action calling `reloadVault()`.
    /// Success never touches it; the store guarantees nothing is lost on a
    /// failure (PRD §18), so this is a report, not a recovery requirement.
    @State private var reorderErrorMessage: String?

    /// - Parameter model: The #14 composition root. The view model starts
    ///   from `model.tasks` (empty before the first load) and is kept in step
    ///   via `onChange` — sections are pure derivations, never stored state.
    ///   Collapse persistence uses the standard `UserDefaults` suite
    ///   (`UserDefaultsCollapseStateStore`; isolated suites in tests).
    init(model: AppModel) {
        self.model = model
        _viewModel = State(initialValue: TasksViewModel(
            tasks: model.tasks,
            collapseStore: UserDefaultsCollapseStateStore(defaults: .standard)))
    }

    var body: some View {
        Group {
            switch model.vaultState {
            case .notConfigured:
                // Issue #26: the real onboarding screen replaces the #15
                // placeholder (Create New Vault default + Choose Existing
                // Vault with the pinned pre-check/consent flow).
                OnboardingView(model: model)
            case .vaultMissing(let path):
                degradedView(
                    title: "Vault folder not found",
                    detail: "The saved vault is unavailable. The path is kept — choose a vault to continue.",
                    path: path)
            case .tasksDirectoryMissing(let path):
                degradedView(
                    title: "Tasks folder not found",
                    detail: "The vault exists but has no Tasks/ folder. The path is kept — choose a vault to continue.",
                    path: path)
            case .loaded:
                loadedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.background)
        .onChange(of: model.tasks) { _, tasks in
            viewModel.updateTasks(tasks)
        }
        .sheet(item: $sessionStartRequest) { request in
            SessionStartView(
                tasks: model.tasks,
                knownCategoryNames: TaskFormState.knownCategoryNames(in: model.tasks),
                    // Issue #34: the manual entry point pre-selects
                    // the last session's target when the request carries
                    // no row hand-off (the sheet filters eligibility
                    // either way).
                    preselectedTargetID: request.preselectedTargetID
                        ?? model.lastSessionTargetID,
                onStart: { taskID, duration in
                    try await model.startSession(taskID: taskID, duration: duration)
                },
                onStartAdHoc: { title, categoryNames, duration in
                    try await model.startAdHocSession(
                        title: title, categoryNames: categoryNames, duration: duration)
                })
        }
        .sheet(item: $formRequest) { request in
            TaskFormView(
                mode: request.mode,
                knownCategoryNames: TaskFormState.knownCategoryNames(in: model.tasks),
                knownProjectNames: TaskFormState.knownProjectNames(in: model.tasks),
                onSave: { task in
                    switch request.mode {
                    case .create:
                        try await model.createTask(task)
                    case .edit:
                        try await model.updateTask(task)
                    }
                })
        }
        .sheet(item: $subtaskFormRequest) { request in
            SubtaskFormView(request: request) { subtask in
                switch request.mode {
                case .create(let parentTaskID, let toParentSubtaskID):
                    try await model.addSubtask(
                        parentID: parentTaskID, subtask: subtask,
                        toParentSubtaskID: toParentSubtaskID)
                case .edit(let parentTaskID, let original):
                    // The #8 editable surface only — the store re-asserts
                    // `id` and discards `children` edits; the form's built
                    // subtask carries the original's id/children anyway.
                    try await model.updateSubtask(
                        parentID: parentTaskID, subtaskID: original.id
                    ) { target in
                        target.title = subtask.title
                        target.status = subtask.status
                        target.priority = subtask.priority
                        target.effort = subtask.effort
                        target.deadline = subtask.deadline
                        target.notes = subtask.notes
                    }
                }
            }
        }
        .alert(
            "Could not delete subtask",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .alert(
            "Could not reorder",
            isPresented: Binding(
                get: { reorderErrorMessage != nil },
                set: { if !$0 { reorderErrorMessage = nil } })
        ) {
            Button("Reload") {
                reorderErrorMessage = nil
                Task { await model.reloadVault() }
            }
            Button("OK", role: .cancel) {
                reorderErrorMessage = nil
            }
        } message: {
            Text(reorderErrorMessage ?? "")
        }
    }

    // MARK: - Loaded (the actual task inventory)

    private var loadedView: some View {
        Group {
            // The transient completion notice (issue #32): a §6.5 "Yes" can
            // move a task's whole tree into the Done group, which §8.3
            // hides with the filter off — the banner names what moved and
            // where it went, so the disappearance is never inexplicable.
            if let notice = model.completionNotice {
                completionNoticeBanner(notice)
            }
            if model.tasks.isEmpty {
                ContentUnavailableView(
                    "No tasks yet",
                    systemImage: "tray",
                    description: Text(
                        "Task files in the vault's Tasks/ folder appear here."))
            } else {
                taskList
            }
        }
        // The #18 keyboard alternative for the *selected* task: ⌘⇧↑ / ⌘⇧↓
        // move it within its group's display order. The shortcuts live on
        // hidden buttons (the standard macOS key-equivalent pattern) so they
        // work outside the row context menu; no selection or a group boundary
        // is a typed no-op. The context menu's Move Up/Down run the same
        // handler.
        .background {
            Group {
                Button("Move Task Up") {
                    moveSelectedTask(up: true)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button("Move Task Down") {
                    moveSelectedTask(up: false)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    formRequest = TaskFormRequest(mode: .create)
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Create a new task (⌘N)")
            }
            ToolbarItem {
                Button {
                    // The #19 toolbar entry point: no row hand-off —
                    // the sheet's pre-selection composes the #34
                    // last-session target in the sheet call below (the
                    // previous session's task when still eligible).
                    // (No keyboard shortcut: the sheet is modal enough
                    // and ⌘S would keep firing behind it.)
                    sessionStartRequest = SessionStartRequest(preselectedTargetID: nil)
                } label: {
                    Label("Start Session", systemImage: "play")
                }
                .help("Start a focus session on a task or subtask")
            }
            ToolbarItem {
                Button {
                    editSelectedTask()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(viewModel.selectedTaskID == nil)
                .help("Edit the selected task (⌘E)")
            }
            ToolbarItem {
                Toggle(isOn: $viewModel.showCompleted) {
                    Label("Show completed/dropped", systemImage: "eye")
                }
                .help("Show Done and Dropped tasks as additional status groups")
            }
        }
    }

    /// The transient completion notice (issue #32): names the task whose
    /// whole tree just moved into the Done group. Auto-expires after a few
    /// seconds (the `.task` timer below — cancelled when the view leaves);
    /// the ✕ button (and the next notice) dismiss it immediately through
    /// `AppModel.dismissCompletionNotice()`.
    private func completionNoticeBanner(_ notice: AppModel.CompletionNotice) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.statusColor(.done))
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                Text("Task “\(notice.taskTitle)” moved to Done")
                    .font(DesignTokens.bodyFont)
                Text("It now lives in the Done group — toggle “Show completed/dropped” to see it.")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.spacingS)
            Button {
                model.dismissCompletionNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(DesignTokens.spacingM)
        .background(DesignTokens.chipBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.panelCornerRadius))
        .task(id: notice) {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            model.dismissCompletionNotice()
        }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if viewModel.sections.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to show", systemImage: "eye.slash")
                    } description: {
                        Text(
                            "Every task is Done or Dropped. "
                                + "Enable “Show completed/dropped” to see them.")
                    } actions: {
                        // Issue #32: one tap resolves the all-done empty
                        // state — the tree the filter is hiding comes back.
                        Button("Show completed/dropped") {
                            viewModel.showCompleted = true
                        }
                    }
                } else {
                    ForEach(viewModel.sections) { section in
                        sectionView(section)
                        if section.id != viewModel.sections.last?.id {
                            Rectangle()
                                .fill(DesignTokens.divider)
                                .frame(height: 1)
                                .padding(.vertical, DesignTokens.spacingS)
                        }
                    }
                }
            }
            .padding(DesignTokens.spacingL)
        }
    }

    /// A project (or No Project) section: a collapsible group of status
    /// sub-groups. Expand/collapse persists through the view model's store.
    private func sectionView(_ section: TaskSection) -> some View {
        DisclosureGroup(isExpanded: viewModel.expandedBinding(forKey: section.collapseKey)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(section.groups) { group in
                    statusGroupView(group)
                }
            }
            .padding(.leading, DesignTokens.spacingM)
        } label: {
            HStack {
                Text(section.displayName)
                    .font(DesignTokens.sectionFont)
                Spacer()
                Text("\(section.totalCount)")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, DesignTokens.spacingS)
            .contentShape(Rectangle())
        }
    }

    /// A status sub-group (To Do / In Progress / Blocked always; Done and
    /// Dropped when the filter is on) containing the task rows in #10 display
    /// order.
    private func statusGroupView(_ group: TaskStatusGroup) -> some View {
        DisclosureGroup(isExpanded: viewModel.expandedBinding(forKey: group.collapseKey)) {
            ForEach(group.tasks) { task in
                TaskRowView(task: task, viewModel: viewModel, subtaskActions: subtaskActions)
                    // #18 drag reorder (within-group only): dragging carries
                    // the task's ID; dropping onto a row of this group reorders
                    // the dragged task to that row's position in the group's
                    // display order. The handler below rejects any ID outside
                    // `group.tasks` — a task belongs to exactly one (project,
                    // status) group, so membership proves the drop stayed
                    // within the source group; every other drop is the pinned
                    // no-op (no container-level drop target exists either).
                    .onDrag {
                        NSItemProvider(object: task.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: RowDropDelegate(
                            destinationIndex: group.tasks.firstIndex(where: {
                                $0.id == task.id
                            }) ?? 0,
                            onDrop: { draggedID, destinationIndex in
                                await applyTaskReorder(
                                    dropping: draggedID, at: destinationIndex, in: group)
                            }))
                    .contextMenu {
                        // The #19 start entry point (nice-to-have
                        // preselection): only on planning-eligible rows — the
                        // start flow refuses Blocked/Dropped/Done with a
                        // pinned reason, so the menu simply doesn't offer it.
                        if task.status.isPlanningEligible {
                            Button("Start Session…") {
                                subtaskActions.startSession(task.id, nil)
                            }
                            Divider()
                        }
                        Button("New Task…") {
                            formRequest = TaskFormRequest(mode: .create)
                        }
                        Button("Add Subtask…") {
                            // Task-level add: the subtask lands in the
                            // task's top-level subtask list (#8: nil).
                            subtaskFormRequest = SubtaskFormRequest(
                                mode: .create(parentTaskID: task.id, toParentSubtaskID: nil))
                        }
                        Button("Edit Task…") {
                            formRequest = TaskFormRequest(mode: .edit(task))
                        }
                        Divider()
                        // The #18 keyboard alternative for this row: a
                        // neighbor swap through the same pipeline as drag
                        // (⌘⇧↑ / ⌘⇧↓ also act on the selected task via the
                        // hidden shortcuts above). Typed no-op at the group
                        // boundary — nil, never a wrap-around.
                        Button("Move Up") {
                            moveTask(task, up: true, in: group)
                        }
                        Button("Move Down") {
                            moveTask(task, up: false, in: group)
                        }
                    }
            }
        } label: {
            HStack(spacing: DesignTokens.spacingS) {
                Circle()
                    .fill(DesignTokens.statusColor(group.status))
                    .frame(
                        width: DesignTokens.statusDotSize,
                        height: DesignTokens.statusDotSize)
                Text(group.status.rawValue)
                    .font(DesignTokens.statusGroupFont)
                Spacer()
                Text("\(group.tasks.count)")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, DesignTokens.spacingXS)
            .contentShape(Rectangle())
        }
    }

    // MARK: - App states

    /// Degraded vault states (`vaultMissing` / `tasksDirectoryMissing`),
    /// per the #14 contract: the stored path is shown and retained — never
    /// silently cleared — and re-selection is offered.
    private func degradedView(title: String, detail: String, path: URL) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DesignTokens.spacingS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.warning)
                VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                    Text(title)
                        .font(DesignTokens.sheetHeaderFont)
                    Text(path.path(percentEncoded: false))
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(detail)
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose vault…", action: chooseVault)
                    .buttonStyle(.bordered)
            }
            .padding(DesignTokens.spacingM)
            .background(DesignTokens.bannerBackground)
            Spacer()
        }
    }

    // MARK: - Subtask form entries (issues #17 + #18)

    /// The add/edit/delete/reorder entry points the task and subtask rows'
    /// context menus expose, wired to the `AppModel` passthroughs. `add` maps
    /// a nil `parentSubtaskID` to a task-level add and any subtask's ID to a
    /// nested add under it (#8); `delete` surfaces a store failure through
    /// the delete alert (the dialog itself closes either way); `reorder`
    /// (#18) reorders one sibling list in place — the caller guarantees the
    /// ID list is an exact permutation of that list — and surfaces a store
    /// failure through the reorder alert.
    private var subtaskActions: SubtaskActions {
        SubtaskActions(
            add: { taskID, parentSubtaskID in
                subtaskFormRequest = SubtaskFormRequest(
                    mode: .create(
                        parentTaskID: taskID, toParentSubtaskID: parentSubtaskID))
            },
            edit: { taskID, subtask in
                subtaskFormRequest = SubtaskFormRequest(
                    mode: .edit(parentTaskID: taskID, subtask: subtask))
            },
            delete: { taskID, subtask in
                do {
                    try await model.deleteSubtask(parentID: taskID, subtaskID: subtask.id)
                } catch {
                    deleteErrorMessage = error.localizedDescription
                }
            },
            reorder: { taskID, parentSubtaskID, siblingIDsInNewOrder in
                do {
                    try await model.reorderSubtasks(
                        parentID: taskID, parentSubtaskID: parentSubtaskID,
                        siblingIDsInNewOrder: siblingIDsInNewOrder)
                } catch {
                    reorderErrorMessage = error.localizedDescription
                }
            },
            // The #19 entry point: open the session-start sheet pre-selecting
            // the row it was invoked from — the subtask's ID, or the task's
            // own ID for a task row (nil subtask).
            startSession: { taskID, subtaskID in
                sessionStartRequest = SessionStartRequest(
                    preselectedTargetID: subtaskID ?? taskID)
            })
    }

    // MARK: - Manual task reordering (issue #18, PRD §8.4)

    /// The one task-reorder pipeline for every entry point (pinned, #18):
    /// **drag and keyboard compose the same arithmetic → `TaskOrdering.reorder`
    /// → `AppModel.reorderTasks` → `VaultStore.applyOrdering` chain.**
    ///
    /// Drag entry point: validates the pinned within-group-only scope (the
    /// dragged ID must already be in this group — a task belongs to exactly
    /// one (project, status) group, so anything else, including a drop aimed
    /// at another group's row, is a no-op) and derives the new ordering with
    /// the pinned remove-then-insert semantics. No optimistic UI: the list
    /// re-renders from `model.tasks` once the store's already-synced
    /// inventory is mirrored back (see `persistTaskReorder`).
    private func applyTaskReorder(
        dropping draggedID: UUID, at destinationIndex: Int, in group: TaskStatusGroup
    ) async {
        let groupIDs = group.tasks.map(\.id)
        guard groupIDs.contains(draggedID),
            let newOrder = ReorderArithmetic.newOrder(
                moving: draggedID, to: destinationIndex, in: groupIDs)
        else { return }
        await persistTaskReorder(in: group, newOrder: newOrder)
    }

    /// Persists one new group ordering: `TaskOrdering.reorder` over the
    /// group's currently persisted `order` values (as displayed) produces the
    /// changed-only `[UUID: Int]`; an empty change set (a no-op drop) writes
    /// nothing. The UI re-renders from the store's synced inventory — the
    /// pinned apply-then-re-render choice (#18; `AppModel.reorderTasks`
    /// mirrors `VaultStore`'s post-write inventory into `model.tasks`, and the
    /// view's `.onChange` rebuilds the sections — no local reorder, no reload).
    /// Any failure surfaces through the non-blocking reorder alert with its
    /// Reload action; success never touches it.
    private func persistTaskReorder(in group: TaskStatusGroup, newOrder: [UUID]) async {
        let currentIDs = group.tasks.map(\.id)
        let currentOrders = Dictionary(
            uniqueKeysWithValues: group.tasks.map { ($0.id, $0.order) })
        let updates: [UUID: Int]
        do {
            updates = try TaskOrdering.reorder(
                currentDisplayOrder: currentIDs, newOrder: newOrder,
                currentOrders: currentOrders)
        } catch {
            // Unreachable for UI-derived input (`ReorderArithmetic` produces
            // exact permutations by construction — tested); surfaced rather
            // than silently dropped (PRD §18).
            reorderErrorMessage = error.localizedDescription
            return
        }
        guard !updates.isEmpty else { return }
        do {
            _ = try await model.reorderTasks(groupUpdates: updates)
        } catch {
            reorderErrorMessage = error.localizedDescription
        }
    }

    /// The context-menu Move Up / Move Down (and the ⌘⇧↑ / ⌘⇧↓ shortcuts'
    /// target): a neighbor swap in the group's display order — a reorder whose
    /// destination index comes from the neighbor, through the exact same
    /// pipeline as drag (pinned, #18). A boundary (first/last row) is a typed
    /// no-op: the swap helper returns nil, never a wrap-around.
    private func moveTask(_ task: TaskItem, up: Bool, in group: TaskStatusGroup) {
        let groupIDs = group.tasks.map(\.id)
        guard let newOrder = up
            ? ReorderArithmetic.swapUp(task.id, in: groupIDs)
            : ReorderArithmetic.swapDown(task.id, in: groupIDs)
        else { return }
        Task { await persistTaskReorder(in: group, newOrder: newOrder) }
    }

    /// The ⌘⇧↑ / ⌘⇧↓ shortcut handler: moves the *selected* task within its
    /// group. No selection, a hidden group (Done/Dropped filter), or a group
    /// boundary is a no-op.
    private func moveSelectedTask(up: Bool) {
        guard let selectedID = viewModel.selectedTaskID,
            let group = viewModel.group(containing: selectedID),
            let task = group.tasks.first(where: { $0.id == selectedID })
        else { return }
        moveTask(task, up: up, in: group)
    }

    // MARK: - Task form entries (issue #16)

    /// Opens the edit form for the currently selected task (the toolbar
    /// Edit button / ⌘E path). A missing selection is a typed no-op — the
    /// button is disabled without one anyway.
    private func editSelectedTask() {
        guard let id = viewModel.selectedTaskID,
            let task = model.tasks.first(where: { $0.id == id })
        else { return }
        formRequest = TaskFormRequest(mode: .edit(task))
    }

    // MARK: - Vault picker

    /// Opens the folder picker and applies the chosen path through
    /// `AppModel.setVaultPath(to:)` (the #14 write path — refusing while a
    /// session is active is surfaced by the model itself; the timer flows
    /// that can activate a session are #19+).
    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose the vault folder that contains Tasks/ and Logs/."
        panel.prompt = "Choose vault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setVaultPath(to: url) }
    }
}
