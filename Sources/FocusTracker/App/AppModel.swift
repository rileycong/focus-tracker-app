import Foundation
import Observation

/// The composition root (issue #14): a `@MainActor @Observable` model that
/// owns and wires every layer built so far — `VaultStore` (#6–#10),
/// `DailyLogStore` (#11), `FocusSessionEngine` + `ActiveSessionCoordinator`
/// (#12/#13) — exposing exactly the observable state the UI (#15+) consumes,
/// plus the settings layer that makes the vault location user-configurable
/// (PRD §5.1 "vault anywhere, path configurable"; PRD §3.1 "the vault is the
/// source of truth" — the app keeps no canonical database of its own).
///
/// # Owned layers (exactly one of each, rebuilt together on a path change)
/// - `vaultStore` / `dailyLogStore` — the two actor stores, pointed at the
///   configured vault URL. Optional by design: before any vault path is
///   configured there is *no* vault to hold, and a `nil` store fails closed —
///   nothing can ever write to a wrong or placeholder location (PRD §18).
///   Non-nil exactly while `vaultURL != nil`, i.e. from construction with a
///   stored path, or after an accepted `setVaultPath(to:)`.
/// - `coordinator` — built over a real `FileActiveSessionPersistence`
///   (app-local Application Support; injectable directory for tests), a real
///   `SystemTickScheduler`, and the pinned autosave interval
///   (`autosaveIntervalSeconds`). The coordinator owns the live
///   `FocusSessionEngine`: the engine is a value type handed to it at init,
///   so all lifecycle mutations flow through the coordinator and the model
///   only ever surfaces coordinator passthroughs — never a divergent copy.
///
/// # Vault state (observable, mirroring `VaultStore.LoadState`)
/// `vaultState` mirrors the store's typed load outcome one-to-one, plus a
/// distinct `.notConfigured` while no path is set (the #15+ onboarding-picker
/// flow keys off it). `tasks` mirrors the loaded inventory's task list
/// (empty in every non-loaded state). `vaultState` is `.notConfigured` at
/// construction and only reflects disk after `bootstrap()`/`reloadVault()`.
///
/// # Vault path change (pinned policy, issue #14)
/// A new path set through `setVaultPath(to:)` recreates both stores against
/// the new URL, reloads, and refreshes all exposed state. If a session is
/// active when the change is requested, the change is **refused until the
/// session ends**, surfaced as the typed `VaultPathChangeOutcome
/// .refusedWhileSessionActive` — nothing is touched: not the stores, not the
/// settings, not the state. This is the simplest safe policy: no active
/// session can end up logging into the wrong vault, and nothing about the old
/// stores is torn down mid-session. The outcome enum is `Equatable` for
/// exact-case assertions.
///
/// # Degraded state (binding, issue #14)
/// After configuration, a vault directory that disappears (moved/deleted)
/// surfaces `.vaultMissing`/`.tasksDirectoryMissing` on the next load while
/// the stored path is **retained** — the model keeps `vaultURL` and never
/// writes back to (never clears) `AppSettings`, so re-selection through the
/// #15+ picker is offered and the user's choice is never silently cleared.
///
/// # Recovery surfacing (#13 → #20/#22 hand-off, issue #14)
/// On startup with a configured vault (`bootstrap()`), the model runs the #13
/// recovery flow: `ActiveSessionPersistence.load()` →
/// `ActiveSessionRecovery.decide`. A `.resume(snapshot)` decision surfaces as
/// the pending resume-or-end state (`pendingSessionRecovery`, holding the
/// snapshot) with the API the UI calls: `restorePendingSession()` (→
/// `ActiveSessionCoordinator.restore(from:)`) or `discardPendingSession()`
/// (→ clears the pending state and the on-disk snapshot). The actual
/// resume/end choice UI is #20/#22 — here it is only state + API, correctly
/// derived. A `.corruptSnapshot` decision is treated as absent (the file was
/// already quarantined by the persistence layer — nothing lost, the decision
/// itself does no I/O).
///
/// # Concurrency shape
/// `@MainActor` throughout: all mutable state is main-actor isolated, the
/// actor stores are bridged with `await`, and the lock-synchronized
/// coordinator is called directly from the main actor (its documented
/// contract). Session lifecycle passthroughs are thin wrappers that keep the
/// observable `sessionState` in step with the coordinator; the real start
/// flow is `startSession`/`startAdHocSession` (#19) and the real end flow is
/// #22.
///
/// # Session start (issue #19, PRD §8.6, §9.1, §9.2, §20.3)
/// `startSession(taskID:duration:)` orchestrates the whole START flow with
/// the pinned refusal order — session already active → vault not configured
/// → pending recovery unresolved → unknown target (`VaultStore.lookup` #6)
/// → the #9 `VaultStore.startSession` transition (Blocked/Dropped/Done
/// refused, In Progress an allowed no-op) → engine start via the
/// `ActiveSessionCoordinator` (which persists the initial snapshot per #13's
/// save-on-start cadence) → the observable app phase swaps to
/// `.timerView(SessionContext)`. `startAdHocSession(title:categoryNames:
/// duration:)` is the §8.6 ad-hoc path: the task is constructed caller-side
/// with status `In Progress` (reusing #16's `TaskFormState` normalization)
/// and created through the existing #7 `VaultStore.create(_:)` — no new
/// creation API — then the session starts on it. Every decision refusal is a
/// typed, `Equatable` `SessionStartOutcome` case (house style); only I/O
/// failures that are not user decisions still throw.
@MainActor
@Observable
public final class AppModel {

    // MARK: - Pinned configuration

    /// The pinned autosave interval (seconds) handed to the
    /// `ActiveSessionCoordinator` (issue #13's cadence contract — also the
    /// honest-loss bound: a hard crash loses at most this much focused time).
    public static let autosaveIntervalSeconds: TimeInterval = 30

    // MARK: - Nested types (the observable state contract)

    /// The observable vault state: `VaultStore.LoadState` mirrored one-to-one
    /// plus a distinct not-configured state (issue #14). Not `Equatable`
    /// because `VaultStore.Inventory` carries `LoadWarning`s with attached
    /// errors; tests pattern-match, as the underlying load state intends.
    public enum VaultState: Sendable {
        /// No vault path is configured (first launch) — the onboarding
        /// picker flow applies (#15+).
        case notConfigured
        /// The vault and its `Tasks/` directory exist; the inventory may
        /// still be empty (empty-but-valid vault) and may carry warnings.
        case loaded(VaultStore.Inventory)
        /// The configured vault path does not exist (or is not a directory).
        case vaultMissing(path: URL)
        /// The vault exists but its `Tasks/` directory is missing.
        case tasksDirectoryMissing(path: URL)

        init(_ loadState: VaultStore.LoadState) {
            switch loadState {
            case .loaded(let inventory): self = .loaded(inventory)
            case .vaultMissing(let path): self = .vaultMissing(path: path)
            case .tasksDirectoryMissing(let path):
                self = .tasksDirectoryMissing(path: path)
            }
        }
    }

    /// The observable active-session state (issue #14): idle, or which phase
    /// the single session lifecycle is in. Tracked by the model at every
    /// lifecycle passthrough so it stays observable — the coordinator is not
    /// an observable object.
    public enum ActiveSessionState: Equatable, Sendable {
        case idle
        case running
        case paused
    }

    /// The typed outcome of a vault path change (pinned policy, issue #14):
    /// `Equatable` so callers and tests can assert the exact case — never a
    /// silent no-op.
    public enum VaultPathChangeOutcome: Equatable, Sendable {
        /// The path was applied: stores recreated, vault reloaded, state
        /// refreshed.
        case changed
        /// Refused because a session was active; nothing was touched (see
        /// the pinned policy in the type documentation).
        case refusedWhileSessionActive
    }

    /// The typed outcome of the pending-recovery actions (`Equatable` for
    /// exact-case assertions; house style: typed outcomes over silent
    /// no-ops).
    public enum PendingRecoveryOutcome: Equatable, Sendable {
        /// The pending snapshot was consumed by this action.
        case restored
        case discarded
        /// There was no pending snapshot — the action was a typed no-op.
        case noPendingSession
    }

    /// The typed failure of a task or subtask write with no vault to write
    /// through (issues #16 + #17): `createTask`/`updateTask` and the subtask
    /// passthroughs (`addSubtask`/`updateSubtask`/`deleteSubtask`) fail
    /// closed when no vault path is configured — nothing can ever write to a
    /// wrong or placeholder location (PRD §18). Store-level failures surface
    /// as thrown `VaultStoreError`s unchanged.
    public enum TaskWriteError: Error, Equatable, Sendable {
        case noVaultConfigured
    }

    /// The display context of a running session (issue #19, PRD §9.1: a
    /// session links to exactly one task/subtask): the linked target's ID
    /// plus the resolved display fields the timer screens (#19 placeholder,
    /// #20) show. Subtasks inherit project/categories from their parent task
    /// (PRD §5.4), resolved at start time. `Equatable` so tests and the
    /// app-phase state can compare exactly.
    public struct SessionContext: Equatable, Sendable {
        /// The session's linked task/subtask ID — the same ID the engine
        /// carries (the eventual §13 log's `task_id`).
        public let taskID: UUID
        /// The target's own title.
        public let title: String
        /// The owning top-level task's title; nil when the target **is** a
        /// top-level task.
        public let parentTaskTitle: String?
        /// The effective project (subtasks inherit, PRD §5.4).
        public let project: Project?
        /// The effective categories (subtasks inherit, PRD §5.4).
        public let categories: [Category]
    }

    /// The observable app phase (issue #19, PRD §20.3): which screen the app
    /// shows. The start flow swaps to `.timerView` on success; `endSession`
    /// returns to `.tasksView` (the #19 placeholder's minimal end path —
    /// #22 owns the real end-of-session flow). The recovery choices
    /// (`restorePendingSession`/`discardPendingSession`) deliberately do not
    /// touch the phase: the actual resume/end choice UI is #20/#22, which
    /// will drive the phase from their own flows.
    public enum AppPhase: Equatable, Sendable {
        case tasksView
        case timerView(SessionContext)
    }

    /// The typed outcome of the #19 start orchestration (`Equatable` for
    /// exact-case assertions — house style, per `VaultPathChangeOutcome`).
    /// Decision refusals are returned, never thrown, so the
    /// `SessionStartView` sheet can surface them inline; only non-decision
    /// I/O failures (vault write-through, snapshot persistence) still throw.
    public enum SessionStartOutcome: Equatable, Sendable {
        /// The session is running and the app phase is
        /// `.timerView(context)`.
        case started(SessionContext)
        /// Refused for the pinned reason (see `SessionStartRefusal`);
        /// nothing was written and no engine was started.
        case refused(SessionStartRefusal)
    }

    /// The pinned refusal vocabulary of the #19 start orchestration, in the
    /// pinned check order (session already active → vault not configured →
    /// pending recovery unresolved → unknown target → #9 status refusal →
    /// ad-hoc validation/creation). Each case is distinct so the sheet can
    /// show a specific inline reason and tests can assert the exact case.
    public enum SessionStartRefusal: Equatable, Sendable {
        /// A session lifecycle is already open (running or paused) — the UI
        /// shows the running timer instead of the start flow (PRD §9.1).
        case sessionAlreadyActive
        /// No vault path is configured (`vaultStore == nil` fails closed,
        /// PRD §18).
        case vaultNotConfigured
        /// A recovered snapshot awaits the user's restore/discard choice
        /// (#14 `pendingSessionRecovery != nil`); a new session cannot start
        /// until it is resolved.
        case pendingRecoveryUnresolved
        /// The target ID is not in the loaded inventory (`VaultStore.lookup`
        /// #6 `.notFound`) — a distinct typed case, never an empty-set
        /// no-op masquerade (#9 contract).
        case unknownTarget(UUID)
        /// The #9 `VaultStore.startSession` transition refused the target:
        /// `Blocked` (manual unblock first), `Dropped` (manual restore only)
        /// or `Done` (nothing to work on). Carries the target ID and the
        /// pinned `StatusTransition.Refusal` reason.
        case targetRefused(UUID, StatusTransition.Refusal)
        /// The ad-hoc task failed validation (PRD §8.6: a title and at
        /// least one category are required — the sheet enforces it live,
        /// the model fails closed the same way).
        case adHocTaskInvalid
        /// The ad-hoc creation write failed (`VaultStore.create` #7 typed
        /// error unchanged — e.g. `.vaultChangedExternally`).
        case adHocCreationFailed(VaultStoreError)
    }

    // MARK: - Owned layers

    /// The task store for the configured vault; nil until a vault path is
    /// configured (fails closed — see the type documentation).
    public private(set) var vaultStore: VaultStore?
    /// The daily-log store for the configured vault; nil until a vault path
    /// is configured.
    public private(set) var dailyLogStore: DailyLogStore?
    /// The session clock shared with the coordinator's engine — the one time
    /// authority the passthroughs below use for `now`.
    public let sessionClock: any FocusSessionClock
    /// The #13 recovery/persistence layer backing the coordinator (app-local
    /// Application Support; injected directory in tests).
    private let persistence: any ActiveSessionPersistence
    private let coordinator: ActiveSessionCoordinator
    private var settings: AppSettings

    // MARK: - Observable state

    /// The configured vault location. Retained even in degraded states —
    /// never silently cleared (binding, issue #14). nil only while
    /// unconfigured.
    public private(set) var vaultURL: URL?
    /// The vault state mirroring the last load, or `.notConfigured` before
    /// any load (also the value while unconfigured).
    public private(set) var vaultState: VaultState = .notConfigured
    /// The tasks from the last successful load, in filename-sorted order.
    /// Empty before the first load and in every non-loaded state.
    public private(set) var tasks: [TaskItem] = []
    /// Which phase the active session is in (see `ActiveSessionState`).
    public private(set) var sessionState: ActiveSessionState = .idle
    /// The pending resume-or-end decision (issue #14 recovery surfacing):
    /// non-nil exactly while a recovered snapshot awaits the user's
    /// restore/discard choice. nil = no pending decision.
    public private(set) var pendingSessionRecovery: ActiveSessionSnapshot?
    /// Which screen the app shows (see `AppPhase`, issue #19). Starts on the
    /// Tasks view; the #19 start flow swaps it to `.timerView` and
    /// `endSession` swaps it back.
    public private(set) var appPhase: AppPhase = .tasksView

    // MARK: - Init

    /// - Parameters:
    ///   - settings: The vault-path settings wrapper (injected suite name —
    ///     the #14 testability seam).
    ///   - persistenceDirectory: Where `FileActiveSessionPersistence` keeps
    ///     the active-session snapshot (the #13 injectable seam; production
    ///     uses the Application Support default).
    ///   - scheduler: The autosave tick scheduler (production: real timer;
    ///     tests: a manual one).
    ///   - sessionClock: The engine's time source (production: real; tests:
    ///     a fake).
    ///   - autosaveInterval: The pinned cadence from #13.
    ///
    /// Construction is synchronous and performs no I/O: the stores are
    /// created when a path is stored, and the actual load + recovery
    /// surfacing happen in `bootstrap()`. After construction (before
    /// `bootstrap()`), `vaultState` is `.notConfigured` by definition.
    public init(
        settings: AppSettings,
        persistenceDirectory: URL = FileActiveSessionPersistence.defaultDirectory,
        scheduler: any ActiveSessionTickScheduler = SystemTickScheduler(),
        sessionClock: any FocusSessionClock = SystemFocusSessionClock(),
        autosaveInterval: TimeInterval = AppModel.autosaveIntervalSeconds
    ) {
        self.settings = settings
        let persistence = FileActiveSessionPersistence(directory: persistenceDirectory)
        self.persistence = persistence
        self.sessionClock = sessionClock
        let vaultURL = settings.vaultPath.map { URL(fileURLWithPath: $0) }
        self.vaultURL = vaultURL
        if let vaultURL {
            self.vaultStore = VaultStore(vaultURL: vaultURL)
            self.dailyLogStore = DailyLogStore(vaultURL: vaultURL)
        }
        self.coordinator = ActiveSessionCoordinator(
            engine: FocusSessionEngine(clock: sessionClock),
            persistence: persistence,
            scheduler: scheduler,
            autosaveInterval: autosaveInterval)
    }

    // MARK: - Startup

    /// The startup sequence (call once after construction; the app root and
    /// tests call this). With a configured vault: reloads it and runs the #13
    /// recovery surfacing. Without one: the model stays `.notConfigured` and
    /// no recovery is surfaced (per the issue, recovery runs on start with a
    /// *configured* vault).
    public func bootstrap() async {
        guard vaultURL != nil else {
            vaultState = .notConfigured
            return
        }
        await reloadVault()
        surfaceRecoveryIfSnapshotPresent()
    }

    // MARK: - Vault state

    /// Re-reads the vault from disk and refreshes the exposed state
    /// (delegates to `VaultStore.load()`). A no-op while unconfigured: the
    /// state stays `.notConfigured` and `tasks` stays empty.
    public func reloadVault() async {
        guard let store = vaultStore else {
            vaultState = .notConfigured
            tasks = []
            return
        }
        let loadState = await store.load()
        vaultState = VaultState(loadState)
        if case .loaded(let inventory) = loadState {
            tasks = inventory.tasks
        } else {
            tasks = []
        }
    }

    // MARK: - Vault path change (pinned policy, issue #14)

    /// Applies a new vault location — the write path of the #15+ Settings
    /// picker. See the pinned policy in the type documentation:
    ///
    /// - **Refused while a session is active** (`.refusedWhileSessionActive`):
    ///   the stores, the settings and all exposed state are untouched, so no
    ///   active session can end up logging into the wrong vault and nothing
    ///   of the old stores is torn down mid-session. The user retries after
    ///   the session ends.
    /// - Otherwise the path is persisted to settings, both stores are
    ///   recreated against the new URL, the vault is reloaded and all
    ///   exposed state refreshed (`.changed`). A missing vault at the new
    ///   location surfaces the degraded state with the path retained — the
    ///   model never writes back to (never clears) settings on degradation.
    @discardableResult
    public func setVaultPath(to newURL: URL) async -> VaultPathChangeOutcome {
        guard !coordinator.isActive else { return .refusedWhileSessionActive }
        settings.vaultPath = newURL.path(percentEncoded: false)
        vaultURL = newURL
        vaultStore = VaultStore(vaultURL: newURL)
        dailyLogStore = DailyLogStore(vaultURL: newURL)
        await reloadVault()
        return .changed
    }

    // MARK: - Recovery surfacing (#13 → #20/#22 hand-off)

    /// Runs the #13 recovery decision over the persisted snapshot and
    /// surfaces the pending resume-or-end state when one is present.
    private func surfaceRecoveryIfSnapshotPresent() {
        let outcome = Result { try persistence.load() }
        switch ActiveSessionRecovery.decide(outcome) {
        case .resume(let snapshot):
            pendingSessionRecovery = snapshot
        case .idle:
            break
        case .corruptSnapshot:
            // Already quarantined by the persistence layer; the snapshot is
            // treated as absent per the #13 contract. Nothing is lost.
            break
        }
    }

    /// The "resume" choice of the pending resume-or-end state (the actual
    /// UI is #20/#22): rehydrates the coordinator's engine from the pending
    /// snapshot via `ActiveSessionCoordinator.restore(from:)` — which also
    /// re-arms the autosave chain — and consumes the pending state. On a
    /// thrown error the pending state is retained, so the decision is not
    /// lost. Without a pending snapshot: the typed `.noPendingSession`.
    @discardableResult
    public func restorePendingSession() throws -> PendingRecoveryOutcome {
        guard let snapshot = pendingSessionRecovery else { return .noPendingSession }
        try coordinator.restore(from: snapshot)
        pendingSessionRecovery = nil
        sessionState = snapshot.isPaused ? .paused : .running
        return .restored
    }

    /// The "end/let it go" choice of the pending resume-or-end state:
    /// clears the pending state **and** the on-disk snapshot, so the same
    /// snapshot cannot re-surface on the next launch. A failed on-disk clear
    /// is deliberately non-fatal and fail-safe: the file is left in place and
    /// will re-surface on the next launch — losing the user's session data
    /// would be the unacceptable direction (PRD §18). Without a pending
    /// snapshot: the typed `.noPendingSession`.
    @discardableResult
    public func discardPendingSession() -> PendingRecoveryOutcome {
        guard pendingSessionRecovery != nil else { return .noPendingSession }
        pendingSessionRecovery = nil
        do {
            try persistence.clear()
        } catch {
            // Documented fail-safe: keep the on-disk snapshot (see above).
        }
        return .discarded
    }

    // MARK: - Task write passthroughs (issue #16, PRD §8.5)

    /// Creates a task through `VaultStore.create` (#7: slug filename +
    /// collision suffix, atomic write, in-memory inventory synced) and
    /// returns the persisted task (with the ID it carries).
    ///
    /// Errors surface typed: `.noVaultConfigured` when there is no store to
    /// write through, and the store's own `VaultStoreError` (e.g.
    /// `.duplicateTaskIDOnCreate`, `.writeFailed`) unchanged on any failure —
    /// on which nothing is written and the observable state is untouched.
    ///
    /// On success the exposed `tasks`/`vaultState` are refreshed from the
    /// store's **already-synced** inventory (engineer's choice documented on
    /// `mirrorSyncedInventory(from:)`) — no reload, no second disk read.
    @discardableResult
    public func createTask(_ task: TaskItem) async throws -> TaskItem {
        guard let store = vaultStore else { throw TaskWriteError.noVaultConfigured }
        let created = try await store.create(task)
        await mirrorSyncedInventory(from: store)
        return created
    }

    /// Persists a full task through `VaultStore.update` (#7: target file
    /// resolved via the ID↔filename mapping — never re-derived from the
    /// title, so a title change keeps the filename; staleness-guarded,
    /// atomic) and returns the persisted task.
    ///
    /// Errors surface typed exactly as on `createTask`. On success the
    /// exposed `tasks`/`vaultState` are refreshed from the store's
    /// already-synced inventory (no reload).
    @discardableResult
    public func updateTask(_ task: TaskItem) async throws -> TaskItem {
        guard let store = vaultStore else { throw TaskWriteError.noVaultConfigured }
        let updated = try await store.update(task)
        await mirrorSyncedInventory(from: store)
        return updated
    }

    /// Mirrors the store's write-synced inventory into the observable state
    /// (issues #16/#17 engineer's choice between `reloadVault()` and
    /// mirroring): #7 keeps the store's `tasks` in step with disk after every
    /// successful write, so the model can refresh without an extra disk
    /// read. The state becomes `.loaded` with the store's current
    /// tasks/warnings — a successful write proves the vault and its `Tasks/`
    /// directory are real, so upgrading a stale degraded display state is
    /// accurate, and `warnings` still describe the last load (per the #7
    /// contract, writes never touch them).
    private func mirrorSyncedInventory(from store: VaultStore) async {
        let syncedTasks = await store.tasks
        let warnings = await store.warnings
        tasks = syncedTasks
        vaultState = .loaded(VaultStore.Inventory(tasks: syncedTasks, warnings: warnings))
    }

    // MARK: - Subtask write passthroughs (issue #17, PRD §5.4, §20.2)

    /// Adds a subtask through `VaultStore.addSubtask(parentID:subtask:
    /// toParentSubtaskID:)` (#8) and returns the updated parent task.
    /// `toParentSubtaskID` nil appends to the task's top-level subtask list;
    /// a non-nil ID appends as the last child of that subtask at any depth.
    ///
    /// Errors surface typed exactly as on `createTask`: `.noVaultConfigured`
    /// when there is no store to write through, and the store's own
    /// `VaultStoreError` (e.g. `.unknownTaskID`, `.unknownSubtaskID`,
    /// `.duplicateSubtaskIDOnAdd`, `.writeFailed`) unchanged on any failure —
    /// on which nothing is written and the observable state is untouched.
    ///
    /// On success the exposed `tasks`/`vaultState` are refreshed from the
    /// store's already-synced inventory (`mirrorSyncedInventory(from:)` — no
    /// reload, no second disk read).
    @discardableResult
    public func addSubtask(
        parentID: UUID, subtask: SubtaskItem, toParentSubtaskID: UUID? = nil
    ) async throws -> TaskItem {
        guard let store = vaultStore else { throw TaskWriteError.noVaultConfigured }
        let updated = try await store.addSubtask(
            parentID: parentID, subtask: subtask, toParentSubtaskID: toParentSubtaskID)
        await mirrorSyncedInventory(from: store)
        return updated
    }

    /// Persists an edit to one subtask through `VaultStore.updateSubtask(
    /// parentID:subtaskID:modified:)` (#8) and returns the updated parent
    /// task. The `apply` closure runs inside the store and must edit only
    /// title/status/priority/effort/deadline/notes (the #8 editable surface —
    /// the store re-asserts `id` and discards `children` edits; the form
    /// never constructs them either). It is `@Sendable` (pure value
    /// manipulation, no isolated state access) so the store can apply it at
    /// write time to the then-current target — the store's actor applies the
    /// edit, never a stale main-actor copy.
    ///
    /// Errors and the observable-state refresh as on `addSubtask`.
    @discardableResult
    public func updateSubtask(
        parentID: UUID, subtaskID: UUID, apply: @Sendable (inout SubtaskItem) -> Void
    ) async throws -> TaskItem {
        guard let store = vaultStore else { throw TaskWriteError.noVaultConfigured }
        let updated = try await store.updateSubtask(
            parentID: parentID, subtaskID: subtaskID, modified: apply)
        await mirrorSyncedInventory(from: store)
        return updated
    }

    /// Removes a subtask — with its whole subtree (#8 semantics) — through
    /// `VaultStore.deleteSubtask(parentID:subtaskID:)`. Siblings and other
    /// branches survive.
    ///
    /// Errors and the observable-state refresh as on `addSubtask`.
    public func deleteSubtask(parentID: UUID, subtaskID: UUID) async throws {
        guard let store = vaultStore else { throw TaskWriteError.noVaultConfigured }
        try await store.deleteSubtask(parentID: parentID, subtaskID: subtaskID)
        await mirrorSyncedInventory(from: store)
    }

    // MARK: - Manual reorder passthroughs (issue #18, PRD §8.4)

    /// Applies a changed-only batch of `ID → new order` updates through
    /// `VaultStore.applyOrdering(groupUpdates:)` (#10) and returns the updated
    /// tasks. The UI derives the batch via `TaskOrdering.reorder` from the
    /// group's display order (drag) or a neighbor swap (keyboard) — one
    /// pipeline for every entry point (pinned, #18); an empty map writes
    /// nothing.
    ///
    /// Errors surface typed exactly as on `createTask`: `.noVaultConfigured`
    /// when there is no store to write through, and the store's own
    /// `VaultStoreError` (e.g. `.vaultChangedExternally`,
    /// `.orderingBatchIncomplete`, `.unknownTaskID`, `.reorderNotExactPermutation`,
    /// `.writeFailed`) unchanged on any failure — on which nothing new is
    /// written and the observable state is untouched.
    ///
    /// On success the exposed `tasks`/`vaultState` are refreshed from the
    /// store's already-synced inventory (`mirrorSyncedInventory(from:)` — the
    /// pinned apply-then-re-render choice, #18: no optimistic local reorder,
    /// no reload, no second disk read).
    @discardableResult
    public func reorderTasks(groupUpdates: [UUID: Int]) async throws -> [TaskItem] {
        guard let store = vaultStore else { throw TaskWriteError.noVaultConfigured }
        let updated = try await store.applyOrdering(groupUpdates: groupUpdates)
        await mirrorSyncedInventory(from: store)
        return updated
    }

    /// Reorders exactly one subtask sibling list through
    /// `VaultStore.reorderSubtasks(parentID:parentSubtaskID:
    /// siblingIDsInNewOrder:)` (#8) and returns the updated parent task.
    /// `parentSubtaskID: nil` reorders the task's top-level subtask list; a
    /// non-nil ID reorders that subtask's children at any depth. The moved
    /// node's whole subtree travels with it (unchanged #8 semantics); the ID
    /// list must be an exact permutation of the targeted list.
    ///
    /// Errors and the observable-state refresh exactly as on `reorderTasks`
    /// (`.noVaultConfigured`, store errors typed unchanged, apply-then-
    /// re-render from the already-synced inventory — no optimistic reorder).
    @discardableResult
    public func reorderSubtasks(
        parentID: UUID, parentSubtaskID: UUID? = nil, siblingIDsInNewOrder: [UUID]
    ) async throws -> TaskItem {
        guard let store = vaultStore else { throw TaskWriteError.noVaultConfigured }
        let updated = try await store.reorderSubtasks(
            parentID: parentID, parentSubtaskID: parentSubtaskID,
            siblingIDsInNewOrder: siblingIDsInNewOrder)
        await mirrorSyncedInventory(from: store)
        return updated
    }

    // MARK: - Session start (issue #19, PRD §8.6, §9.1, §9.2, §20.3)

    /// Starts a focus session on an existing task or subtask — the #19
    /// START orchestration over the picked target, with the pinned refusal
    /// order. Each step is a distinct typed case on the returned
    /// `SessionStartOutcome`; nothing silent:
    ///
    /// 1. **Session already active** → `.refused(.sessionAlreadyActive)`.
    /// 2. **Vault not configured** → `.refused(.vaultNotConfigured)` (fails
    ///    closed, PRD §18).
    /// 3. **Pending recovery unresolved** (#14) →
    ///    `.refused(.pendingRecoveryUnresolved)`; the user resolves the
    ///    pending snapshot via `restorePendingSession()` /
    ///    `discardPendingSession()` first.
    /// 4. **Target resolution** via `VaultStore.lookup(_:)` (#6: a subtask
    ///    at any depth, or a top-level task) — an unknown ID is its own
    ///    typed case `.unknownTarget`, never an empty-set masquerade (#9).
    /// 5. **#9 `VaultStore.startSession(_:)` transition**: To Do → In
    ///    Progress write-through (whole-file atomic write); In Progress →
    ///    allowed no-op (the session proceeds); Blocked/Dropped/Done →
    ///    `.refused(.targetRefused(_:reason))` — the sheet surfaces the
    ///    reason inline.
    /// 6. **Engine start** via the `ActiveSessionCoordinator` passthrough,
    ///    which persists the initial snapshot (#13 save-on-start cadence).
    /// 7. **App phase** swaps to `.timerView(SessionContext)` with the
    ///    resolved title/project/categories (`FocusTrackerApp` swaps
    ///    screens on it; the placeholder timer is #19's, the real one #20's).
    ///
    /// Steps 1–3 and 4–5 share one implementation each
    /// (`startPrerequisitesRefusal()` / the #9 store wrapper), and
    /// `startAdHocSession` reuses both, so the pinned order cannot drift
    /// between the two entry points.
    ///
    /// - Parameters:
    ///   - taskID: The picked task/subtask ID.
    ///   - duration: The session length in seconds (PRD §9.2 default 25
    ///     minutes; the sheet enforces the positive-integer rule on its
    ///     minutes field — the model trusts the engine's own contract).
    /// - Throws: Only non-decision I/O failures, unchanged: the store's
    ///   `VaultStoreError` (e.g. `.vaultChangedExternally` on the transition
    ///   write — the status change stands, the retry then takes the
    ///   In-Progress no-op path) and the coordinator's snapshot-persistence
    ///   error. Neither is a user decision, so both stay thrown (house
    ///   style: typed outcomes only *where a user decision is involved*).
    @discardableResult
    public func startSession(
        taskID: UUID,
        duration: TimeInterval = FocusSessionEngine.defaultDurationSeconds
    ) async throws -> SessionStartOutcome {
        if let refusal = startPrerequisitesRefusal() { return .refused(refusal) }
        guard let store = vaultStore else {
            // Same check the preamble just made — narrowed for flow typing.
            return .refused(.vaultNotConfigured)
        }

        // Step 4: target resolution (subtask at any depth or top-level task).
        let context: SessionContext
        switch await store.lookup(taskID) {
        case .task(let task):
            context = SessionContext(
                taskID: task.id, title: task.title, parentTaskTitle: nil,
                project: task.project, categories: task.categories)
        case .subtask(let subtask, in: let parent):
            context = SessionContext(
                taskID: subtask.id, title: subtask.title,
                parentTaskTitle: parent.title, project: parent.project,
                categories: parent.categories)
        case .notFound:
            return .refused(.unknownTarget(taskID))
        }

        // Step 5: the #9 startSession transition. `.transitioned` covers both
        // allowed shapes — the non-empty To Do → In Progress change set and
        // the empty In-Progress no-op set (the session proceeds either way).
        let outcome = try await store.startSession(taskID)
        switch outcome {
        case .transitioned:
            break
        case .refused(let reason):
            return .refused(.targetRefused(taskID, reason))
        case .unknownID(let unknown):
            // Defensive: the lookup above proved existence, so this only
            // fires on an inventory divergence mid-flow — surfaced as the
            // same typed unknown case, never a masquerade (#9 contract).
            return .refused(.unknownTarget(unknown))
        }
        // Keep the observable inventory in step after a status write-through
        // (a no-op change set writes nothing, so this is a cheap mirror).
        await mirrorSyncedInventory(from: store)

        return try beginEngineSession(
            onTask: taskID, context: context, duration: duration)
    }

    /// Starts a focus session on a **new ad-hoc task** (issue #19, PRD
    /// §8.6): the task is constructed caller-side with status `In Progress`
    /// — the documented ad-hoc path (`StatusTransition` header, #9: no new
    /// creation API) — and created through the existing #7
    /// `VaultStore.create(_:)` (one Markdown file, atomic write, synced
    /// inventory), then the session starts on the new task's ID.
    ///
    /// The pinned refusal order's first three cases are shared with
    /// `startSession` (already active → not configured → pending recovery);
    /// the ad-hoc-specific steps follow: title/category validation (PRD
    /// §8.6 — a title and at least one category required; normalization
    /// **reuses #16's `TaskFormState` token logic verbatim** — trim,
    /// case-insensitive dedupe) fails closed as `.adHocTaskInvalid`, and a
    /// failed creation write surfaces as `.adHocCreationFailed(storeError)`
    /// with nothing started.
    ///
    /// - Parameters:
    ///   - title: The raw ad-hoc title (trimmed here, as the #16 form does).
    ///   - categoryNames: The raw category tokens (normalized through
    ///     `TaskFormState.commitCategory`).
    ///   - duration: The session length in seconds (default 25 minutes,
    ///     PRD §9.2).
    /// - Throws: As on `startSession` — only non-decision I/O failures.
    @discardableResult
    public func startAdHocSession(
        title: String,
        categoryNames: [String],
        duration: TimeInterval = FocusSessionEngine.defaultDurationSeconds
    ) async throws -> SessionStartOutcome {
        if let refusal = startPrerequisitesRefusal() { return .refused(refusal) }
        guard let store = vaultStore else {
            return .refused(.vaultNotConfigured)
        }

        // Ad-hoc validation through the #16 form-state logic: the same
        // trimming/dedupe the task form applies, with the status pinned to
        // In Progress (PRD §8.6 / #9's documented ad-hoc construction).
        var form = TaskFormState()
        form.title = title
        for name in categoryNames { form.commitCategory(name) }
        form.status = .inProgress
        guard form.hasValidTitle, form.hasValidCategories else {
            return .refused(.adHocTaskInvalid)
        }
        let task: TaskItem
        do {
            task = try form.makeTask(preserving: nil)
        } catch {
            // Unreachable with the guards above (the only thrown case is
            // the empty-categories one); failed-closed rather than forced.
            return .refused(.adHocTaskInvalid)
        }

        let created: TaskItem
        do {
            created = try await store.create(task)
        } catch let error as VaultStoreError {
            return .refused(.adHocCreationFailed(error))
        }
        await mirrorSyncedInventory(from: store)

        let context = SessionContext(
            taskID: created.id, title: created.title, parentTaskTitle: nil,
            project: created.project, categories: created.categories)
        return try beginEngineSession(
            onTask: created.id, context: context, duration: duration)
    }

    /// The shared pinned-refusal preamble (issue #19's check order, steps
    /// 1–3): session already active → vault not configured → pending
    /// recovery unresolved. `nil` = all three passed.
    private func startPrerequisitesRefusal() -> SessionStartRefusal? {
        if coordinator.isActive { return .sessionAlreadyActive }
        if vaultStore == nil { return .vaultNotConfigured }
        if pendingSessionRecovery != nil { return .pendingRecoveryUnresolved }
        return nil
    }

    /// The shared engine-start tail (issue #19 steps 6–7): coordinator start
    /// (persisting the initial snapshot per #13's save-on-start cadence),
    /// the observable session-state tracking, and the app-phase swap.
    /// Snapshot-persistence failures are not user decisions — they throw
    /// unchanged (see `startSession`'s error contract).
    private func beginEngineSession(
        onTask taskID: UUID, context: SessionContext, duration: TimeInterval
    ) throws -> SessionStartOutcome {
        try coordinator.start(taskID: taskID, duration: duration)
        sessionState = .running
        appPhase = .timerView(context)
        return .started(context)
    }

    /// Pauses (coordinator passthrough) and tracks the observable state.
    public func pauseSession() throws {
        try coordinator.pause()
        sessionState = .paused
    }

    /// Resumes (coordinator passthrough) and tracks the observable state.
    public func resumeSession() throws {
        try coordinator.resume()
        sessionState = .running
    }

    /// Ends the session (coordinator passthrough: engine result + snapshot
    /// clear) and returns to idle, swapping the app phase back to
    /// `.tasksView` (the #19 placeholder's minimal end path — #22 owns the
    /// real end-of-session flow and will compose its own).
    @discardableResult
    public func endSession() throws -> FocusSessionResult {
        let result = try coordinator.end()
        sessionState = .idle
        appPhase = .tasksView
        return result
    }

    /// Whether a session lifecycle is currently open (authoritative
    /// coordinator passthrough).
    public var isSessionActive: Bool { coordinator.isActive }

    /// See `FocusSessionEngine.focusedSeconds(at:)`, evaluated at the shared
    /// clock's current monotonic reading. Time-derived: not reactive on its
    /// own (the timer views drive re-rendering, #20/#21).
    public var focusedSeconds: TimeInterval {
        coordinator.focusedSeconds(at: sessionClock.monotonicSeconds)
    }

    /// See `FocusSessionEngine.remainingSeconds(at:)`.
    public var remainingSeconds: Int? {
        coordinator.remainingSeconds(at: sessionClock.monotonicSeconds)
    }

    /// See `FocusSessionEngine.progressFraction(at:)`.
    public var progressFraction: Double {
        coordinator.progressFraction(at: sessionClock.monotonicSeconds)
    }

    /// See `FocusSessionEngine.isExpired(at:)`.
    public var isSessionExpired: Bool {
        coordinator.isExpired(at: sessionClock.monotonicSeconds)
    }
}
