import SwiftUI

/// The app's default view (issue #15, PRD §8.2): the read-only task inventory
/// grouped per PRD §8.3, driven by the #14 composition root. Rendering and
/// sub-structure live in the `Views/` group; this type wires the observable
/// state — `AppModel.vaultState` decides the app state (onboarding, degraded
/// banner, loaded), and `AppModel.tasks` is mirrored into the
/// `TasksViewModel` whose sections/selection the list renders.
struct TasksView: View {
    private let model: AppModel
    @State private var viewModel: TasksViewModel

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
                notConfiguredView
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
    }

    // MARK: - Loaded (the actual task inventory)

    private var loadedView: some View {
        Group {
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
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $viewModel.showCompleted) {
                    Label("Show completed/dropped", systemImage: "eye")
                }
                .help("Show Done and Dropped tasks as additional status groups")
            }
        }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if viewModel.sections.isEmpty {
                    ContentUnavailableView(
                        "Nothing to show",
                        systemImage: "eye.slash",
                        description: Text(
                            "Every task is Done or Dropped. "
                                + "Enable “Show completed/dropped” to see them."))
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
                TaskRowView(task: task, viewModel: viewModel)
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

    /// First launch (`notConfigured`): minimal onboarding placeholder with
    /// the "Choose vault…" folder picker (the real Settings flow is #16+).
    private var notConfiguredView: some View {
        VStack(spacing: DesignTokens.spacingM) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Focus Tracker")
                .font(.title2)
            Text(
                "Point the app at a vault folder that contains a Tasks/ "
                    + "folder — the tasks there show up in this list.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose vault…", action: chooseVault)
                .buttonStyle(.bordered)
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: 380)
    }

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
                        .font(.headline)
                    Text(path.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(detail)
                        .font(.caption)
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
