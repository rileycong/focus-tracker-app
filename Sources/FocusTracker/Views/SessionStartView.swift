import SwiftUI

/// The #19 session-start sheet presentation request, wired by `TasksView`
/// like the #16/#17 sheet requests. Fresh identity per presentation (the
/// `let id = UUID()` pattern of `TaskFormRequest`), plus the optional
/// preselected target for the row context-menu entry points.
struct SessionStartRequest: Identifiable {
    let id = UUID()
    /// The task/subtask ID pre-selected in the picker (issue #19
    /// nice-to-have): a row's context menu hands over that row's ID; the
    /// toolbar entry passes nil. An ID that is not planning-eligible (the
    /// context menus only offer the action on eligible rows anyway, but an
    /// inventory may change in between) simply leaves the picker without a
    /// selection — never a crash.
    let preselectedTargetID: UUID?
}

/// The session-start sheet (issue #19, PRD §8.6, §9.1, §9.2): from here the
/// user either (a) **picks an eligible existing task/subtask** — the pure
/// `SessionStartPicker` grouping over the plain inventory, searchable — or
/// (b) **creates an ad-hoc task inline** (title + at least one category,
/// PRD §8.6, reusing #16's `TaskFormState` category token logic verbatim),
/// then starts a focus session with a configurable duration (default 25
/// minutes, PRD §9.2).
///
/// # Wiring
/// The view performs **no model work itself**: the `onStart`/`onStartAdHoc`
/// closures are wired by `TasksView` to `AppModel.startSession` /
/// `AppModel.startAdHocSession`. Every typed refusal (`SessionStartOutcome
/// .refused`) surfaces **inline in the sheet** — the sheet stays open and
/// shows the reason — while a thrown I/O error (not a user decision) is
/// shown inline through its localized description for the same reason.
/// `.started` dismisses the sheet; the app phase swap to the timer screen
/// is the model's job.
///
/// # Duration field (documented engineer's choice)
/// A plain minutes text field defaulting to "25". Invalid input (empty,
/// non-numeric, zero, negative, fractional — `parseDurationMinutes`) both
/// disables Start **and** shows an inline hint: the issue pins
/// "prevented or typed-refused", and prevention needs no extra refusal case
/// in the model's pinned refusal order. No fixed preset buttons (PRD §9.2).
struct SessionStartView: View {

    /// The sheet's two modes: pick an existing eligible target, or create
    /// the ad-hoc task inline (PRD §8.6's two paths).
    enum Mode: Hashable {
        case pick
        case create
    }

    /// The inventory snapshot to pick from (`AppModel.tasks` at presentation
    /// time — the sheet is short-lived; no live sync needed).
    let tasks: [TaskItem]
    /// The category combobox's suggestion list (#16 pattern:
    /// `TaskFormState.knownCategoryNames(in:)`, gathered by `TasksView`).
    let knownCategoryNames: [String]
    /// The preselected target ID (see `SessionStartRequest`).
    let preselectedTargetID: UUID?
    /// The start handler over an existing target (→ `AppModel.startSession`).
    let onStart: (UUID, TimeInterval) async throws -> AppModel.SessionStartOutcome
    /// The ad-hoc start handler (→ `AppModel.startAdHocSession`).
    let onStartAdHoc: (String, [String], TimeInterval) async throws
        -> AppModel.SessionStartOutcome

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .pick
    @State private var query = ""
    @State private var selectedTargetID: UUID?
    /// The ad-hoc form state — #16's `TaskFormState` reused wholesale: only
    /// the title and category fields are exposed (PRD §8.6: "no other
    /// fields — optional metadata is added later via the normal forms"), and
    /// the status is pinned to In Progress by the model's ad-hoc path.
    @State private var adHoc = TaskFormState()
    @State private var durationText = "25"
    @State private var inlineMessage: String?
    @State private var isStarting = false

    // MARK: - Derived state

    private var eligibleTargets: [SessionStartTarget] {
        SessionStartPicker.eligibleTargets(in: tasks)
    }

    private var sections: [SessionStartSection] {
        SessionStartPicker.sections(
            from: eligibleTargets.filter { SessionStartPicker.matches($0, query: query) })
    }

    private var selectedTarget: SessionStartTarget? {
        eligibleTargets.first { $0.id == selectedTargetID }
    }

    /// The parsed duration in minutes (nil = invalid — Start disabled).
    private var durationMinutes: Int? {
        Self.parseDurationMinutes(durationText)
    }

    private var canStart: Bool {
        guard !isStarting, durationMinutes != nil else { return false }
        switch mode {
        case .pick: return selectedTarget != nil
        case .create: return adHoc.isValid
        }
    }

    /// The category combobox's suggestions: the inventory's known names the
    /// form has not committed yet (#16 combobox pattern).
    private var categorySuggestions: [String] {
        knownCategoryNames.filter { !adHoc.containsCategory(named: $0) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Start mode", selection: $mode) {
                Text("Pick a task").tag(Mode.pick)
                Text("New ad-hoc task").tag(Mode.create)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(DesignTokens.spacingM)

            switch mode {
            case .pick:
                pickerSection
            case .create:
                adHocSection
            }

            Divider()
            footer
        }
        .frame(width: 460, height: 500)
        .background(DesignTokens.background)
        .onAppear {
            // The row context-menu nice-to-have: pre-select the requested
            // target when it is eligible (#19, documented on
            // `SessionStartRequest`).
            if selectedTargetID == nil,
                eligibleTargets.contains(where: { $0.id == preselectedTargetID })
            {
                selectedTargetID = preselectedTargetID
            }
        }
    }

    // MARK: - Mode (a): the eligible picker

    private var pickerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search tasks…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, DesignTokens.spacingM)
                .padding(.bottom, DesignTokens.spacingS)
            if sections.isEmpty {
                ContentUnavailableView(
                    "No eligible tasks",
                    systemImage: "tray",
                    description: Text(
                        "To Do or In Progress tasks and subtasks can be started. "
                            + "Create an ad-hoc task instead."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            sectionHeader(section)
                            ForEach(section.groups) { group in
                                groupHeader(group)
                                ForEach(group.targets) { target in
                                    targetRow(target)
                                }
                            }
                            if section.id != sections.last?.id {
                                Rectangle()
                                    .fill(DesignTokens.divider)
                                    .frame(height: 1)
                                    .padding(.vertical, DesignTokens.spacingS)
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.spacingM)
                    .padding(.bottom, DesignTokens.spacingM)
                }
            }
        }
    }

    private func sectionHeader(_ section: SessionStartSection) -> some View {
        HStack {
            Text(section.displayName)
                .font(DesignTokens.sectionFont)
            Spacer()
            Text("\(section.totalCount)")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.spacingS)
    }

    private func groupHeader(_ group: SessionStartGroup) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Circle()
                .fill(DesignTokens.statusColor(group.status))
                .frame(
                    width: DesignTokens.statusDotSize,
                    height: DesignTokens.statusDotSize)
            Text(group.status.rawValue)
                .font(DesignTokens.statusGroupFont)
            Spacer()
            Text("\(group.targets.count)")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.spacingXS)
        .padding(.leading, DesignTokens.spacingM)
    }

    private func targetRow(_ target: SessionStartTarget) -> some View {
        Button {
            selectedTargetID = target.id
        } label: {
            HStack(spacing: DesignTokens.spacingS) {
                Circle()
                    .fill(DesignTokens.statusColor(target.status))
                    .frame(
                        width: DesignTokens.statusDotSize,
                        height: DesignTokens.statusDotSize)
                    .accessibilityLabel(Text(target.status.rawValue))
                VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                    Text(target.title)
                        .font(DesignTokens.bodyFont)
                        .lineLimit(1)
                    if target.depth > 0 {
                        Text(target.parentTaskTitle)
                            .font(DesignTokens.annotationFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DesignTokens.spacingM)
            }
            .padding(.vertical, DesignTokens.rowVerticalPadding)
            .padding(.horizontal, DesignTokens.spacingS)
            .background(
                selectedTargetID == target.id
                    ? DesignTokens.selectionBackground : Color.clear)
            .cornerRadius(DesignTokens.cornerRadius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            selectedTargetID == target.id ? AccessibilityTraits.isSelected : [])
    }

    // MARK: - Mode (b): the ad-hoc task

    private var adHocSection: some View {
        Form {
            Section {
                TextField("Title", text: $adHoc.title)
                categoryField
                if !adHoc.categoryNames.isEmpty {
                    categoryChips
                }
                Text(
                    "Title and at least one category (PRD §8.6). The task is "
                        + "created In Progress in the vault; add the optional "
                        + "details later through the task's Edit form.")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignTokens.spacingM)
        .scrollContentBackground(.hidden)
    }

    /// The #16 category combobox pattern, compact: Enter commits the whole
    /// draft, commas commit complete segments, and the menu offers the
    /// inventory's known names not yet committed.
    private var categoryField: some View {
        HStack(spacing: DesignTokens.spacingS) {
            TextField("Category (Enter or comma to add)", text: $adHoc.categoryDraft)
                .onSubmit { adHoc.commitWholeDraft() }
                .onChange(of: adHoc.categoryDraft) { _, _ in
                    adHoc.commitCompletedCategorySegments()
                }
            if !categorySuggestions.isEmpty {
                Menu {
                    ForEach(categorySuggestions, id: \.self) { name in
                        Button(name) { adHoc.commitCategory(name) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Suggested categories from the vault")
            }
        }
    }

    private var categoryChips: some View {
        FlowChips(names: adHoc.categoryNames) { name in
            adHoc.removeCategory(name)
        }
    }

    // MARK: - Footer (duration + refusal surface + actions)

    private var footer: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            if let message = inlineMessage {
                Text(message)
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(DesignTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                HStack(spacing: DesignTokens.spacingXS) {
                    Text("Duration (min):")
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(.secondary)
                    TextField("25", text: $durationText)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    if isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Start", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, DesignTokens.spacingM)
    }

    // MARK: - Actions

    private func start() {
        guard let minutes = durationMinutes, !isStarting else { return }
        let seconds = TimeInterval(minutes) * 60
        isStarting = true
        inlineMessage = nil
        let adHocTitle = adHoc.title
        let adHocCategories = adHoc.categoryNames
        Task {
            do {
                let outcome: AppModel.SessionStartOutcome
                switch mode {
                case .pick:
                    guard let target = selectedTarget else {
                        isStarting = false
                        return
                    }
                    outcome = try await onStart(target.id, seconds)
                case .create:
                    outcome = try await onStartAdHoc(adHocTitle, adHocCategories, seconds)
                }
                finish(outcome)
            } catch {
                // A thrown I/O failure (not a user decision) surfaces inline
                // for the same reason the typed refusals do.
                isStarting = false
                inlineMessage = error.localizedDescription
            }
        }
    }

    private func finish(_ outcome: AppModel.SessionStartOutcome) {
        isStarting = false
        switch outcome {
        case .started:
            dismiss()
        case .refused(let refusal):
            inlineMessage = Self.refusalMessage(refusal)
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// The duration field's parse rule (issue #19): a positive whole number
    /// of minutes; nil for anything else (empty, non-numeric, zero,
    /// negative, fractional). Documented choice: invalid input *prevents*
    /// starting (Start disabled + inline hint) rather than adding a refusal
    /// case to the model's pinned order.
    static func parseDurationMinutes(_ raw: String) -> Int? {
        guard
            let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            value >= 1
        else { return nil }
        return value
    }

    /// The user-facing inline copy for each typed refusal (the sheet stays
    /// open and shows the reason — never an alert storm, #19).
    static func refusalMessage(_ refusal: AppModel.SessionStartRefusal) -> String {
        switch refusal {
        case .sessionAlreadyActive:
            return "A session is already running."
        case .sessionEndingUnresolved:
            return
                "A session just ended — finish the wrap-up form before starting a new one."
        case .breakActive:
            return
                "A break is running — finish or end the break before starting a session."
        case .postSessionChoiceActive:
            return
                "Choose what's next (start a session or take a break) before starting one here."
        case .vaultNotConfigured:
            return "No vault is configured. Choose a vault folder first."
        case .pendingRecoveryUnresolved:
            return
                "A recovered session is waiting to be resumed or ended. Resolve it before starting a new one."
        case .unknownTarget:
            return "That task is no longer in the inventory. Close this sheet and try again."
        case .targetRefused(_, .blocked):
            return "This item is Blocked — unblock it before starting a session."
        case .targetRefused(_, .dropped):
            return "This item is Dropped — restore it before starting a session."
        case .targetRefused(_, .alreadyDone):
            return "This item is already Done — nothing to work on."
        case .adHocTaskInvalid:
            return "An ad-hoc task needs a title and at least one category."
        case .adHocCreationFailed(let error):
            return "Could not save the ad-hoc task: \(error)"
        }
    }
}

/// A minimal wrapping chip row (the #16 form's category chip language,
/// compact enough for the sheet): each committed name as a capsule with a
/// remove button.
private struct FlowChips: View {
    let names: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)],
            alignment: .leading,
            spacing: DesignTokens.spacingXS
        ) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: DesignTokens.spacingXS) {
                    Text(name)
                        .font(DesignTokens.chipFont)
                        .lineLimit(1)
                    Button {
                        onRemove(name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: DesignTokens.chipRemoveIconSize))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Remove \(name)"))
                }
                .padding(.horizontal, DesignTokens.spacingS)
                .padding(.vertical, DesignTokens.spacingXS)
                .background(DesignTokens.chipBackground)
                .cornerRadius(DesignTokens.cornerRadius)
            }
        }
    }
}
