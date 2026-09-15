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
/// derived. **Issue #36 closes that deferred-UI gap** with ONE phase-driven
/// prompt (the #22 modal pattern, presented by the app shell): surfacing a
/// `.resume` decision ALSO swaps the app phase to `.recoveryPrompt`, and the
/// prompt's two actions drive the phase from here — `restorePendingSession()`
/// → `.timerView`, `discardPendingSession()` → `.tasksView`. A
/// `.corruptSnapshot` decision is treated as absent (the file was
/// already quarantined by the persistence layer — nothing lost, the decision
/// itself does no I/O).
///
/// # Mini mode (issue #21, PRD §10.2)
/// `isMiniTimerActive` is an observable flag **beside `.timerView`** — not a
/// distinct `AppPhase` case (pinned engineer's choice, documented): the
/// phase stays `.timerView(context)` through a collapse/restore; the flag
/// selects full or compact content inside the same main window.
/// `collapseToMiniTimer()` refuses when no session is active;
/// `restoreFromMiniTimer()` touches nothing but the flag. `endSession()`
/// clears the flag and also clears the #20 session-number snapshot.
/// Nothing is persisted: on relaunch the app defaults to the full view (the
/// #14 recovery flow resurfaces a pending session there).
///
/// # End of session (issue #22, PRD §9.5, §12, §13, §6.5, §20.6)
/// `endSession()` is the confirm-End step: the coordinator end runs the
/// engine end + the #13 clear-on-end snapshot wipe, `sessionState` goes
/// `.idle` from the confirm instant, the mini flag and the #20
/// session-number snapshot are cleared, and the phase swaps to
/// `.endingSession(result, context)` — the REQUIRED end-of-session modal
/// over the timer, presented by the app shell (ONE phase-driven path).
/// Ending from mini restores the main window's normal presentation with the
/// modal over it. While `.endingSession`, `startSession`/`startAdHocSession`
/// refuse with the typed `.sessionEndingUnresolved` and `setVaultPath`
/// refuses (the pending result must log into the vault the session ran
/// against, §18). `submitEndOfSession(_:)` composes the §13 log purely
/// (`EndOfSessionFormState.makeLog`), LOGS FIRST to the END day
/// (`logDay(forEndedAt:)` — a midnight-spanning session logs to its end
/// day), then applies the §6.5 completion on Yes, with typed
/// `EndOfSessionOutcome` results for the honest two-write atomicity
/// reality: a log-append failure retains the ending state for retry, a
/// completion failure after a successful log is the documented partial
/// outcome (back on Tasks). Issue #23 reroutes the flow's exit: the two
/// outcomes that leave the modal (`.success`, `.completionFailedAfterLog`)
/// stop at `.postSessionChoice` — the explicit Start Next Session / Take
/// Break choice, nothing auto-starting — instead of landing directly on
/// Tasks; `.logAppendFailed` keeps the modal up for retry. Issue #27 adds
/// the escape hatch for that state (`discardEndOfSession` — typed confirm
/// in the modal drops the unsubmitted result, honest §18 loss, nothing
/// written) and reconciles the composed log's whole-minute fields so the
/// append check passes for ANY session (see `EndOfSessionFormState.makeLog`).
/// Issue #29 adds the modal's Cancel: `endSession()` captures the
/// end-instant engine snapshot via a read-only coordinator passthrough
/// BEFORE `coordinator.end()` and retains it in the `.endingSession` phase
/// payload; `cancelEndOfSession()` discards the retained result as a log
/// (nothing appended) and restores the session through the #13
/// `coordinator.restore(from:)` path — running-at-end re-anchored running
/// (modal time counts as nothing), paused-at-end restored paused (modal
/// time lands in paused, never focused) — with the pinned ordering
/// restore → state updates → phase swap so no guard-gap exists.
///
/// Issue #32 adds the completion discoverability surface: when the §6.5
/// completion's change set contains the owning top-level task, its WHOLE
/// tree just left the active groups (PRD §8.3 hides Done/Dropped by
/// default, so the completed tree visibly disappears from the list). The
/// submission then sets `completionNotice` — a transient, dismissible
/// banner the Tasks view renders ("Task "X" moved to Done") — so the move
/// is never inexplicable. A subtask completion that does NOT complete its
/// top-level owner changes nothing discoverable and sets no notice.
///
/// # Expiry alarm + focus-back auto-end (issue #33, PRD §9.5, §14.4)
/// Issue #33 AMENDS the #12 pinned expiry decision ("expiry is pure state;
/// focused keeps accumulating past expiry"): from this issue, expiry means
/// the session ENDS — with `ended_at` pinned to the expiry instant — via a
/// composition-layer amendment exactly like #27's; the engine is
/// UNCHANGED (it still reports pure expiry state and keeps its honest
/// second-precision accumulators; the amendment lives entirely here).
/// The orchestration:
///
/// - **Detection (~1 s granularity, view-tick-driven):** the timer views'
///   watch tasks call `evaluateSessionExpiry()` about once per second while
///   a session is active (the same ~1 s cadence the break view's tick uses
///   for `isBreakExpired`). The call is idempotent and cheap; detection is
///   therefore within ~1 s of `remainingSeconds` hitting 0, the same
///   granularity as the countdown display itself.
/// - **Expiry while UNFOCUSED → alarm:** the `ExpiryAlarmController` (the
///   alarm's one AppKit seam — the system beep ~1×/s + the
///   `didBecomeActive` focus-back watch) starts beeping, and
///   `isExpiryAlarmActive` flips true — `TimerView` shakes while it is on.
///   The alarm loops bounded (one invalidated-on-stop timer, one observer,
///   no per-tick state) for as long as the user ignores it.
/// - **Focus-back → stop + auto-end + modal, NO confirm:** on
///   `didBecomeActive` while alarming, the alarm stops and the session is
///   auto-ended (`autoEndExpiredSession`) — SKIPPING the End/Cancel confirm
///   (user-pinned in #33: the confirm remains for manual End only) — and
///   the phase swaps to `.endingSession`: the standard #22 modal.
/// - **Expiry while ACTIVE → no alarm, straight to auto-end + modal:** the
///   next ~1 s watcher tick sees expired + focused and auto-ends directly.
///   Whichever path lands first wins: a manual End in the sub-second window
///   before the tick keeps its confirm and its wall-clock `ended_at`.
/// - **Expiry-instant log semantics (the amendment):** the auto-end
///   composes the retained result with
///   `ended_at = started_at + duration` (the expiry instant — no overrun
///   counted) and `focusedDuration` = the configured duration in whole
///   minutes, so the modal shows the honest "N min focused". The #27 span
///   reconciliation in `EndOfSessionFormState.makeLog` then guarantees the
///   append invariant exactly: the wall span IS the duration, so
///   `focused + paused == duration` minutes precisely (paused keeps the
///   engine's pre-expiry pauses; any post-expiry time is excluded by the
///   span, never logged as overrun).
/// - **Cancel-resume of an expired session (#29 × #33):** the auto-end
///   retains an EXPIRY-INSTANT snapshot (not the end-time one): focused
///   accumulators pinned to exactly `duration`, pre-expiry paused seconds,
///   `isPaused == false` (expiry is only reachable while running — focused
///   freezes while paused), so Cancel restores the session AT its expiry
///   state. Resuming an expired session counts further time as focused
///   (the restore re-anchors a run segment; the engine's #12 semantics do
///   the rest) and the NEXT end reconciles again through the ordinary #27
///   composition. The expiry watcher does NOT re-fire for that session
///   (the per-session watch state — see `ExpiryWatchState`): the user just
///   chose to continue it; a fresh start re-arms the watcher.
/// - **#13 recovery interplay:** an expired-but-unended session still
///   recovers as today (the snapshot was persisted on start/cadence). A
///   recovery RESTORE of an already-expired snapshot is marked handled by
///   the same rule as cancel-resume (the user explicitly resumed it; no
///   instant re-end), while a restore below the duration watches normally
///   and will legitimately alarm/auto-end when it expires in-process. If
///   the user instead force-quits while the alarm runs, recovery handles
///   it unchanged on the next launch.
/// - **Mini mode:** starting the alarm from mini restores the full timer
///   (the shake is a full-window affordance; the alarm must be visible),
///   reusing the existing same-window presentation sync. Compact mode itself
///   never shakes (documented engineer's choice).
///
/// # Break flow (issue #23, PRD §14)
/// The opt-in break behind the post-submission choice: `takeBreak(duration:)`
/// starts a `BreakTimerEngine` (default 5 minutes, configured at the choice
/// step before start only) and swaps the phase to `.breakActive`; the break
/// view renders the countdown from the model's pure passthroughs and the
/// `TimelineView` tick. Expiry is observable (`isBreakExpired`) and surfaces
/// an IN-APP banner — no system notifications, no auto-dismiss, no
/// auto-start. `endBreak()` serves both the End-break-early control and the
/// post-expiry path back: engine end → `BreakLog` composed from the result →
/// `DailyLogStore.appendBreak` to the END day via `logDay(forEndedAt:)`
/// reused AS-IS → `.sessionStart` in every outcome (#34 amendment — was:
/// `.tasksView`). Log failure is NON-BLOCKING
/// by pinned design (small warning + continue — documented divergence from
/// the session flow's retry-in-place). While a break runs,
/// `startSession`/`startAdHocSession` refuse (`.breakActive`), and so does
/// `setVaultPath` (the break will append through the current stores); during
/// the choice phase the starts refuse too (`.postSessionChoiceActive`) but
/// `setVaultPath` does not — nothing is pending a write yet.
///
/// # Direct session-start routing + last-task pre-selection (issue #34)
/// Issue #34 AMENDS #23's pinned exit routing (documented at every
/// affected site): the post-session choice's **Start Next Session** and
/// EVERY break end (`endBreak` — the expiry acknowledgment, the early
/// end, and the non-blocking log-failure path) swap the phase to
/// `.sessionStart`, presenting the #19 session-start sheet DIRECTLY
/// (was: `.tasksView`). The menu always shows and nothing auto-starts
/// — the user still confirms duration and presses Start (the #23
/// non-goals hold; only the landing screen changed). The sheet
/// pre-selects `lastSessionTargetID` — the task/subtask of the most
/// recent successful start (recorded by `beginEngineSession` for BOTH
/// entry points; in-memory only: it survives end/submit/cancel/discard,
/// is overwritten by the next start, and dies with the process, per the
/// user's "has not quit the application" scoping) — filtered at
/// presentation time by current eligibility
/// (`SessionStartPicker.preselectedTargetID(requesting:in:)`: still in
/// the inventory, not Done/Blocked/Dropped), so a Done or gone previous
/// task leaves the picker unselected. The manual toolbar entry
/// (TasksView) composes the same pre-selection for its sheet. The
/// sheet's Cancel routes through `cancelSessionStart()` back to
/// `.tasksView`. Starts are NOT refused while `.sessionStart` is up —
/// it IS the start surface. Ad-hoc mode is unaffected; the duration
/// default stays 25.
///

/// # Concurrency shape
/// `@MainActor` throughout: all mutable state is main-actor isolated, the
/// actor stores are bridged with `await`, and the lock-synchronized
/// coordinator is called directly from the main actor (its documented
/// contract). Session lifecycle passthroughs are thin wrappers that keep the
/// observable `sessionState` in step with the coordinator; the real start
/// flow is `startSession`/`startAdHocSession` (#19) and the real end flow is
/// #22 (`endSession()` + `submitEndOfSession`).
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

    /// Process-local lifecycle counters used by the issue #37 diagnostic
    /// harness to detect scene-driven model recreation.
    private(set) static var initializationCount = 0
    private(set) static var bootstrapCount = 0

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
    /// shows. The start flow swaps to `.timerView` on success; the end flow
    /// (#22) moves it to `.endingSession` on confirm and to `.tasksView`
    /// only when the required modal is submitted. The recovery choices drive
    /// the phase too (issue #36, closing #14's deferred-UI gap): surfacing a
    /// pending recovery swaps to `.recoveryPrompt`, and the prompt's Resume
    /// → `.timerView` / Discard → `.tasksView` (see that case).
    public enum AppPhase: Equatable, Sendable {
        case tasksView
        case timerView(SessionContext)
        /// The end-of-session flow is open (issue #22, PRD §12): the engine
        /// has ended (`sessionState` is already `.idle`) and the
        /// §13-destined `FocusSessionResult` is retained here together with
        /// the session's display context — the payload the modal shows and
        /// the submission consumes, while the timer stays rendered
        /// underneath. The app shell presents the end-of-session modal for
        /// exactly this phase — ONE presentation path.
        ///
        /// The middle payload member is the #29 end-instant snapshot,
        /// captured via the coordinator's read-only `captureSnapshot()`
        /// BEFORE `coordinator.end()` (after end the engine is idle and
        /// capture returns `nil` — order matters). It retains the exact
        /// pause state at end (`isPaused`), the second-precision
        /// accumulators, the pause count and the configured `duration` —
        /// none of which `FocusSessionResult` carries — so the modal's
        /// Cancel can restore the session faithfully via the #13
        /// `restore(from:)` path. **Rejected alternatives (documented,
        /// issue #29):** adding `is_paused_at_end` to the result (ripples
        /// the #12 result shape and still lacks the configured duration —
        /// the result carries only rounded minutes), and synthesizing a
        /// snapshot from the result alone (loses `duration` and second
        /// precision; restoring from rounded minutes would inject rounding
        /// error into a live session). The ≈0 time between the capture and
        /// the end is absorbed by the restore re-anchor on Cancel. The
        /// snapshot is DROPPED — never restorable — when the phase leaves
        /// `.endingSession` by submission (the payload is replaced by
        /// `.postSessionChoice`) AND by #27's discard (replaced by
        /// `.tasksView`).
        ///
        /// Issue #33 adds a second, confirm-less ENTRANCE to this phase:
        /// the expiry auto-end (the ~1 s watcher tick on expiry-while-
        /// active, or the alarm's focus-back) swaps here directly — the
        /// End/Cancel confirm remains for manual End only. On that path the
        /// payload is the EXPIRY-INSTANT composition (engine unchanged, the
        /// #27 precedent): the result's `endedAt` is pinned to
        /// `startedAt + duration` — amending #12's accumulate-past-expiry,
        /// no overrun is counted — with `focusedDuration` = the configured
        /// duration in whole minutes, and the snapshot is the expiry-instant
        /// state (focused == duration, pre-expiry pauses, `isPaused` false)
        /// — exactly what Cancel restores. See the type documentation.
        ///
        /// Submission is REQUIRED (§12.5): the phase stays here until
        /// `submitEndOfSession` lands (success or the typed partial
        /// outcome) or `cancelEndOfSession` (#29) restores the session;
        /// while it lasts, `startSession`/`startAdHocSession` refuse with
        /// `.sessionEndingUnresolved` and `setVaultPath` refuses.
        /// **Honest loss window (documented, accepted v1):** the result
        /// lives only in memory — the snapshot was already cleared at
        /// confirm — so an app quit while the modal is up loses the
        /// unsubmitted session. The modal is app-modal and blocking.
        /// Quitting is NOT blocked while this phase is up (#27, verified):
        /// nothing implements `applicationShouldTerminate` — the one app
        /// delegate (#30) answers only the last-window-closed policy
        /// (AppKit default `true` unless mini-collapsed) — the modal is a
        /// plain SwiftUI sheet, and the app is single-window (#27
        /// amendment) — the default AppKit terminate path ends the app
        /// normally on Cmd+Q.
        case endingSession(FocusSessionResult, ActiveSessionSnapshot, SessionContext)
        /// The post-submission choice (issue #23, PRD §14.1, §20.7): after a
        /// submission that leaves the end-of-session modal — BOTH
        /// `.success` and the typed `.completionFailedAfterLog` partial
        /// outcome, the two outcomes that leave the flow — the flow stops
        /// here for the explicit **Start Next Session / Take Break** choice.
        /// NOTHING auto-starts and NO break auto-begins (§14.1; §19
        /// non-goals: automatic break start).
        ///
        /// Payload (engineer's choice, documented): the §6.5 completion
        /// failure carried through from the `.completionFailedAfterLog`
        /// submission — nil on the `.success` path — so the choice view
        /// surfaces the #22 partial-outcome warning inline and the insertion
        /// does not swallow #22's documented guidance. `.logAppendFailed`
        /// does NOT reach this phase (the modal stays up for retry).
        ///
        /// Presentation (engineer's choice, documented): a plain inline view
        /// swapped in by the app shell's ONE phase-driven path — after the
        /// blocking modal the timer has nothing to render under a sheet, so
        /// a full calm screen is more honest than a small sheet over
        /// nothing. `startSession`/`startAdHocSession` refuse with the
        /// typed `.postSessionChoiceActive` (defensive single-lifecycle
        /// parity); `setVaultPath` does NOT refuse here — nothing is pending
        /// a write until a break actually starts.
        case postSessionChoice(completionFailure: VaultStoreError?)
        /// The break countdown is running (issue #23, PRD §14.2).
        /// Payload-free (engineer's choice, documented): a break links to no
        /// task, so there is no display context to carry — the break view
        /// derives every value from the model's break-engine passthroughs
        /// (`breakRemainingSeconds`, `breakProgressFraction`,
        /// `isBreakExpired`). While this phase is up,
        /// `startSession`/`startAdHocSession` refuse with the typed
        /// `.breakActive` and `setVaultPath` refuses (the pending break will
        /// `appendBreak` through the current stores, §18). Only the user's
        /// actions leave it — no auto-dismiss, no auto-start (§14.3).
        case breakActive
        /// The phase-driven session-start presentation (issue #34,
        /// AMENDING #23's pinned exit routing): the app shows the #19
        /// session-start sheet DIRECTLY. Two entrances: the post-session
        /// choice's **Start Next Session** (was: `.tasksView` — the #23
        /// "no auto-open" decision is reversed by user request; the menu
        /// still shows and nothing auto-STARTS: the user still confirms
        /// duration and presses Start) and every break end (`endBreak` —
        /// the expiry acknowledgment and the early end alike, after the
        /// `appendBreak` write lands, including its non-blocking failure
        /// path). Payload-free (engineer's choice, documented): the sheet
        /// derives tasks, category names and the #34 pre-selection from
        /// the model's current state (`lastSessionTargetID`), exactly as
        /// the shell derives every other view's inputs; eligibility is
        /// filtered by the sheet via
        /// `SessionStartPicker.preselectedTargetID(requesting:in:)` — a
        /// Done/Blocked/Dropped or absent previous task leaves the picker
        /// unselected. Unlike `.postSessionChoice`, starts are NOT refused
        /// here — this phase IS the start surface: the sheet's controls
        /// run the ordinary #19 flow and swap to `.timerView` on success.
        /// `setVaultPath` does not refuse either (nothing is pending a
        /// write — the `.postSessionChoice` policy). The sheet's Cancel
        /// routes through `cancelSessionStart()` back to `.tasksView`
        /// (no dismissal environment to fall back on — the phase owns
        /// the presentation).
        case sessionStart
        /// The pending-recovery prompt (issue #36, PRD §9.5): a recovered
        /// (unfinished) session awaits the user's Resume/Discard choice.
        /// EXACTLY ONE presentation in the app shell — the #22 modal
        /// pattern (`TasksView` underneath, sheet over it, interactive
        /// dismissal disabled) — keyed off this phase so the prompt is
        /// impossible to miss and impossible to duplicate: `bootstrap()`
        /// is the single surfacing site (normal launch, quit-with-running-
        /// session and crash recovery all converge there), and the pending
        /// state is only consumed by the prompt's two actions.
        ///
        /// Payloads (engineer's choice, documented): the `snapshot` is the
        /// #13 persisted image — the prompt's focused-time readout and the
        /// session identity the actions resolve; the `SessionContext` is
        /// resolved ONCE at surfacing (`recoveryContext(for:)`) — the
        /// snapshot's task ID looked up in the just-reloaded inventory
        /// (task or subtask at any depth, the #19 lookup shape), an
        /// unknown ID (deleted target, changed vault) → the generic
        /// `recoveredSessionGenericTitle` wording. The lookup result is
        /// carried rather than re-derived so the prompt and the post-resume
        /// timer show the SAME wording, and no view ever touches the store.
        ///
        /// While this phase is up, `startSession`/`startAdHocSession` are
        /// unreachable from the UI (the prompt blocks the app; the #19
        /// `.pendingRecoveryUnresolved` refusal stays as the defensive
        /// backstop — verified). `setVaultPath` does not refuse (the
        /// snapshot is app-local, not vault-bound — §13's pinned scope).
        ///
        /// Exits: `restorePendingSession()` (#14 API — the engine restores
        /// per #13, autosave re-armed; #33 semantics — an already-expired
        /// snapshot restores AT its expiry-instant state and the watcher is
        /// marked handled) → `.timerView(context)`; `discardPendingSession()`
        /// (after the prompt's typed, destructive confirm — the session was
        /// never logged, §18 honest loss) → `.tasksView`, starts allowed.
        case recoveryPrompt(ActiveSessionSnapshot, SessionContext)
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
    /// pinned check order (session already active → end-of-session flow
    /// unresolved (#22) → break active (#23) → post-session choice (#23) →
    /// vault not configured → pending recovery unresolved → unknown target →
    /// #9 status refusal → ad-hoc validation/creation). Each case is
    /// distinct so the sheet can show a specific inline reason and tests can
    /// assert the exact case.
    public enum SessionStartRefusal: Equatable, Sendable {
        /// A session lifecycle is already open (running or paused) — the UI
        /// shows the running timer instead of the start flow (PRD §9.1).
        case sessionAlreadyActive
        /// The end-of-session flow is unresolved (issue #22, §12.5): a
        /// session has ended and the REQUIRED modal is still up
        /// (`.endingSession`). The engine is already idle at this point, so
        /// `coordinator.isActive` alone no longer guards the
        /// single-lifecycle rule — this typed case does. The user submits
        /// (or retries through a log-append failure) first.
        case sessionEndingUnresolved
        /// A break is running (issue #23 criterion 19, PRD §14.3): the
        /// break flow owns the app until the user ends it — finish or end
        /// the break first, then start normally.
        case breakActive
        /// The post-submission choice is up (issue #23 criterion 20, the
        /// `.sessionEndingUnresolved` precedent): the choice screen blocks
        /// the app, so this is defensive typed parity for the
        /// single-lifecycle rule — cheap, and it keeps every guarded state
        /// in the pinned chain. Choose Start Next Session (or take a break
        /// and end it) first.
        case postSessionChoiceActive
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

    /// The transient completion notice (issue #32): what the Tasks view
    /// surfaces when a §6.5 completion moved a top-level task's whole tree
    /// into the Done group. `Equatable` for exact assertions.
    public struct CompletionNotice: Equatable, Sendable {
        /// The moved task's title — the name the banner shows.
        public let taskTitle: String

        public init(taskTitle: String) {
            self.taskTitle = taskTitle
        }
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
    /// The #33 expiry alarm (its one AppKit seam — the system beep + the
    /// activation watch; injectable for tests). Constructed here when not
    /// injected; its callbacks are wired to the observable flag and the
    /// focus-back auto-end below.
    private let expiryAlarm: ExpiryAlarmController
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
    /// Which screen the app shows (see `AppPhase`, issues #19 + #22 + #23
    /// + #34). Starts on the Tasks view; the #19 start flow swaps it to
    /// `.timerView`, the #22 confirm swaps it to `.endingSession`, the
    /// required modal submission moves the flow to `.postSessionChoice`
    /// (#23), and — the #34 amendment of #23's pinned exit — the choice's
    /// **Start Next Session** and every break end swap to `.sessionStart`
    /// (the session-start sheet, directly); only the sheet's Cancel
    /// (`cancelSessionStart()`) and the #27 discard return to
    /// `.tasksView`.
    public private(set) var appPhase: AppPhase = .tasksView
    /// Mini-mode flag (issue #21, PRD §10.2): true exactly while the main
    /// main window uses the always-on-top compact presentation. Pinned choice: a
    /// flag beside `.timerView`, NOT a distinct `AppPhase` case (see the
    /// type documentation) — the phase stays `.timerView(context)` through
    /// collapse/restore. Set by `collapseToMiniTimer()` (session-active
    /// only), cleared by `restoreFromMiniTimer()` and by `endSession()` (the
    /// compact presentation ends on a session end by any path). In-memory only — nothing
    /// is persisted (issue criterion 5: relaunch defaults to the full view).
    public private(set) var isMiniTimerActive = false
    /// The #20 session-number snapshot (issue #21 criterion 2), lifted into
    /// the model: `TimerView` fetches it once on appear via
    /// `DailyLogStore.sessions(for:on:)` and records it here; the mini view
    /// reads the same value with **no refetch**. nil = unavailable (no
    /// vault, or fetch failure) — the "Session N today" line is gracefully
    /// omitted in both views. Reset on every new engine session (a fresh
    /// fetch, never a stale number) and on `endSession()`.
    public private(set) var sessionNumberToday: Int?
    /// The transient completion notice (issue #32): set by
    /// `submitEndOfSession` exactly when the §6.5 completion's change set
    /// contains the owning top-level task — i.e. its whole tree just moved
    /// into Done and, with the §8.3 filter off, left the visible list. The
    /// Tasks view renders it as a dismissible banner (auto-expiring there);
    /// `dismissCompletionNotice()` clears it. nil = nothing to surface.
    public private(set) var completionNotice: CompletionNotice?
    /// The #33 expiry-alarm flag: true exactly while the alarm controller
    /// is beeping (`ExpiryAlarmController.isAlarming`, mirrored here through
    /// its `onStateChange` callback so the observable layer drives the
    /// shake animation). The alarm only runs while a session sits expired
    /// with the app UNFOCUSED; it stops on focus-back (then the auto-end),
    /// on any other session end (defensive), and on model teardown.
    public private(set) var isExpiryAlarmActive = false
    /// The task/subtask ID of the most recent successfully STARTED
    /// session (issue #34): recorded by `beginEngineSession` — the shared
    /// tail of both #19 entry points (existing target and ad-hoc) — and
    /// handed to the session-start sheet as its pre-selection candidate.
    /// In-memory ONLY, by pinned design: the user scoped the pre-selection
    /// to "has not quit the application", so nothing is persisted and a
    /// fresh `AppModel` (a relaunch) starts with nil — there is no clear
    /// call, the value simply dies with the model instance. It survives
    /// the session's end, submission, cancel and discard (it records the
    /// START, not the lifecycle) and is overwritten by every next
    /// successful start. The sheet filters it by current eligibility
    /// (still in the inventory, not Done/Blocked/Dropped) at presentation
    /// time — the tracking itself is kept unconditional so the model
    /// stays an honest "what did I last work on".
    public private(set) var lastSessionTargetID: UUID?

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
    ///   - expiryAlarm: The #33 alarm controller (injectable for tests —
    ///     a production one with the real system-beep/activation probe is
    ///     constructed when nil; its callbacks are wired to
    ///     `isExpiryAlarmActive` and the focus-back auto-end either way).
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
        autosaveInterval: TimeInterval = AppModel.autosaveIntervalSeconds,
        expiryAlarm: ExpiryAlarmController? = nil
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
        let alarm = expiryAlarm ?? ExpiryAlarmController()
        self.expiryAlarm = alarm
        // Wired after full initialization (the closures capture self):
        // the shake flag rides the alarm's state changes, and the focus-back
        // signal runs the #33 auto-end (the controller already stopped the
        // alarm before delivering it).
        alarm.onStateChange = { [weak self] active in
            self?.isExpiryAlarmActive = active
        }
        alarm.onFocusBack = { [weak self] in
            self?.autoEndExpiredSession()
        }
        Self.initializationCount += 1
    }

    // MARK: - Startup

    /// The startup sequence (call once after construction; the app root and
    /// tests call this). With a configured vault: reloads it and runs the #13
    /// recovery surfacing (issue #36: a `.resume` decision also swaps the app
    /// phase to `.recoveryPrompt` — the app shell's ONE prompt presentation,
    /// up before any other surface can start anything). Without one: the
    /// model stays `.notConfigured` and no recovery is surfaced (per the
    /// issue, recovery runs on start with a *configured* vault).
    public func bootstrap() async {
        Self.bootstrapCount += 1
        guard vaultURL != nil else {
            vaultState = .notConfigured
            return
        }
        await reloadVault()
        await surfaceRecoveryIfSnapshotPresent()
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
    /// - **Refused while a session is active or ending**
    ///   (`.refusedWhileSessionActive`): the stores, the settings and all
    ///   exposed state are untouched, so no active session can end up
    ///   logging into the wrong vault and nothing of the old stores is torn
    ///   down mid-session. The user retries after the session ends. #22
    ///   extends the refusal to the unresolved end-of-session flow
    ///   (`.endingSession`): the pending result must log into the vault the
    ///   session ran against (§18) — the stores may not be swapped out from
    ///   under it. #23 extends it once more to a running break
    ///   (`.breakActive`): the pending break will `appendBreak` through the
    ///   current stores, and the path may not be swapped out from under a
    ///   write-in-flight flow (§18). While the post-session choice phase is
    ///   up it does NOT refuse — nothing is pending a write until the break
    ///   actually starts.
    /// - Otherwise the path is persisted to settings, both stores are
    ///   recreated against the new URL, the vault is reloaded and all
    ///   exposed state refreshed (`.changed`). A missing vault at the new
    ///   location surfaces the degraded state with the path retained — the
    ///   model never writes back to (never clears) settings on degradation.
    ///
    /// The pinned refusal chain and the storing tail are shared verbatim
    /// with the #26 creation/onboarding-selection flows
    /// (`isVaultLocationChangeRefused` / `applyVaultLocation(_:)`), so the
    /// one-storing-code-path rule (#14, reused by #26) cannot drift. The
    /// method's own behavior is unchanged.
    @discardableResult
    public func setVaultPath(to newURL: URL) async -> VaultPathChangeOutcome {
        guard !isVaultLocationChangeRefused else { return .refusedWhileSessionActive }
        await applyVaultLocation(newURL)
        return .changed
    }

    /// The pinned vault-location-change refusal chain (issue #14, extended
    /// by #22/#23), shared by `setVaultPath(to:)` and the #26
    /// creation/onboarding-selection flows: true when a session is active,
    /// the end-of-session flow is unresolved, or a break is running. The
    /// `.postSessionChoice` phase deliberately does NOT refuse — nothing is
    /// pending a write until the break actually starts (the existing
    /// #14/#23 policy; #26 pins the same chain for `createVault` and the
    /// choose-existing selection). Defensive only for #26: onboarding is
    /// reachable solely when unconfigured.
    private var isVaultLocationChangeRefused: Bool {
        if coordinator.isActive { return true }
        // Issue #22: the pending result must log into the vault the session
        // ran against (§18) — see `setVaultPath`'s policy documentation.
        if case .endingSession = appPhase { return true }
        // Issue #23 (criterion 21): a pending break appends through the
        // CURRENT stores — the path may not move under the write-in-flight
        // flow (§18). The choice phase deliberately does not refuse
        // (nothing is pending a write until the break starts).
        if case .breakActive = appPhase { return true }
        return false
    }

    /// The ONE storing code path for a vault location (issue #14 semantics,
    /// reused verbatim by the #26 `createVault`/`selectExistingVault`
    /// flows): persists the path to `AppSettings.vaultPath` exactly as
    /// before (`newURL.path(percentEncoded: false)` — one settings key, no
    /// parallel path), recreates both stores against the URL and reloads,
    /// refreshing all exposed state.
    private func applyVaultLocation(_ newURL: URL) async {
        settings.vaultPath = newURL.path(percentEncoded: false)
        vaultURL = newURL
        vaultStore = VaultStore(vaultURL: newURL)
        dailyLogStore = DailyLogStore(vaultURL: newURL)
        await reloadVault()
    }

    // MARK: - First-run vault creation + onboarding selection (issue #26)

    /// The typed outcome of `createVault(parentURL:name:)` — issue #26's
    /// pinned create-path matrix (`Equatable` for exact-case assertions,
    /// house style). Every non-collision, non-refused outcome ends with the
    /// path stored through the one `setVaultPath` storing path
    /// (`applyVaultLocation(_:)`): settings written, both stores recreated,
    /// vault reloaded — the app lands on the Tasks view (`.loaded`).
    public enum VaultCreationOutcome: Equatable, Sendable {
        /// `<parent>/<name>` was absent: the vault root + `Tasks/` +
        /// `Logs/` were created.
        case created(URL)
        /// `<parent>/<name>` existed as a directory with missing structure:
        /// **ONLY the missing directories** were scaffolded (an explicit
        /// create operation — no consent step on this path, pinned);
        /// existing content untouched. Distinct from `.created` (engineer's
        /// choice, documented): tests and callers can tell a fresh vault
        /// from a repaired one without diffing the disk.
        case scaffolded(URL)
        /// `<parent>/<name>` was an already-valid vault: used as-is —
        /// ZERO writes to the vault; existing files byte-identical.
        case usedExisting(URL)
        /// A non-directory occupies the target itself, or a needed folder
        /// path (`<name>`, `Tasks`, `Logs`) is occupied by a file. Collision
        /// detection precedes ANY mkdir (pinned): nothing was modified —
        /// e.g. `Tasks` occupied while `Logs/` is missing creates no
        /// `Logs/`. Carries the target URL for the inline error.
        case nameCollision(URL)
        /// Refused under the same conditions `setVaultPath` refuses (see
        /// `isVaultLocationChangeRefused`); nothing was touched.
        case refusedWhileSessionActive
    }

    /// The typed outcome of the onboarding choose-existing flow (issue #26;
    /// `Equatable`, house style). The pre-check itself is onboarding-level:
    /// `OnboardingView` runs the pinned `VaultStructureValidator` on the
    /// picked folder BEFORE calling this method, to decide whether consent
    /// UI is needed — this method then applies the user's decision and is
    /// the only path that mutates anything. `setVaultPath` itself is
    /// unchanged (its degraded-state re-selection flow keeps current
    /// behavior — out of scope).
    public enum ExistingVaultOutcome: Equatable, Sendable {
        /// The folder was structurally valid: applied via `setVaultPath`
        /// exactly as today (`.changed` semantics) — zero writes to the
        /// vault. No consent required (pinned: the frictionless case).
        case selected(URL)
        /// Structure was missing and the user consented: ONLY the missing
        /// directories were scaffolded (the same helper as the create
        /// path), then the path stored like a normal selection.
        case scaffolded(URL)
        /// Consent was declined: typed cancelled outcome — NOTHING on disk
        /// modified, path NOT stored; the app stays `.notConfigured`.
        case cancelled(URL)
        /// A file occupies `Tasks` or `Logs` under the picked folder: typed
        /// inline error; nothing modified; no scaffold offer.
        case nameCollision(URL)
        /// Defensive refusal parity with `setVaultPath`; nothing touched.
        case refusedWhileSessionActive
    }

    /// Creates (or completes) the vault at `<parent>/<name>` — the issue #26
    /// create-path matrix, the default first-run flow:
    ///
    /// 1. **Name sanitization** (`VaultFolderNameSanitizer`, the house slug
    ///    character policy without `.md`/`untitled`) runs first — pure, and
    ///    an empty result is the typed `SanitizationError.emptyAfterSanitize`
    ///    before anything is examined (the UI disables Create on the same
    ///    rule; this is fail-closed defense).
    /// 2. **Refusal chain** — exactly `setVaultPath`'s
    ///    (`isVaultLocationChangeRefused`); nothing is touched on refusal.
    /// 3. **Collision detection BEFORE any mkdir** (pinned): a file at
    ///    `<parent>/<name>` itself, or the validator's `.nameCollision`
    ///    (pinned precedence: collision over missing), returns
    ///    `.nameCollision` with nothing modified — `Tasks` occupied while
    ///    `Logs/` is missing does NOT create `Logs/`.
    /// 4. **Absent target** → root + `Tasks/` + `Logs/` created
    ///    (`.created`); **directory with missing structure** → ONLY the
    ///    missing dirs scaffolded, existing content untouched
    ///    (`.scaffolded`); **valid directory** → zero writes
    ///    (`.usedExisting`).
    /// 5. **On success** the path is stored exactly as `setVaultPath` does
    ///    (`applyVaultLocation(_:)` — one storing code path) and the app
    ///    lands on Tasks (`.loaded`; an empty inventory's "No tasks yet" is
    ///    the fine expected state).
    ///
    /// A mid-creation I/O failure (not a user decision) throws — house
    /// style — leaving what was already created on disk, the path unstored;
    /// a retry re-validates and finishes (idempotent by the matrix).
    @discardableResult
    public func createVault(
        parentURL: URL, name: String
    ) async throws -> VaultCreationOutcome {
        let folderName = try VaultFolderNameSanitizer.sanitize(name)
        if isVaultLocationChangeRefused { return .refusedWhileSessionActive }

        // The target URL carries NO directory-annotated trailing slash, so
        // the stored settings path matches the plain-path convention of the
        // picker-based `setVaultPath` flow, and the existence probe below
        // cannot be fooled by `stat("…/<name>/")`'s ENOTDIR on a file.
        let vaultURL = parentURL.appendingPathComponent(folderName)
        let targetPath = vaultURL.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory) {
            // The target exists: a non-directory is the typed collision
            // (nothing modified); otherwise the validator classifies it.
            guard isDirectory.boolValue else { return .nameCollision(vaultURL) }
            let validation = VaultStructureValidator.validate(at: vaultURL)
            switch validation {
            case .nameCollision:
                return .nameCollision(vaultURL)
            case .valid:
                // Use as-is — zero writes to the vault (pinned).
                await applyVaultLocation(vaultURL)
                return .usedExisting(vaultURL)
            case .missingTasks, .missingLogs, .bothMissing:
                // Scaffold ONLY the missing dirs (explicit create — no
                // consent step on the create path, pinned).
                try VaultScaffolder.scaffoldMissingDirectories(
                    at: vaultURL, validation: validation)
                await applyVaultLocation(vaultURL)
                return .scaffolded(vaultURL)
            }
        }
        // Absent: create the root, then the canonical structure.
        try VaultScaffolder.createRoot(at: vaultURL)
        try VaultScaffolder.scaffoldMissingDirectories(
            at: vaultURL, validation: .bothMissing)
        await applyVaultLocation(vaultURL)
        return .created(vaultURL)
    }

    /// Applies the user's decision for a folder picked on the onboarding
    /// "Choose Existing Vault…" flow (issue #26). The onboarding-level
    /// pre-check (`VaultStructureValidator.validate(at:)`, run by the view
    /// BEFORE any `setVaultPath`) decides which consent UI the user saw;
    /// this method re-validates and applies the decision — the ONE path
    /// that mutates anything:
    ///
    /// - `.valid` → applied via `setVaultPath(to:)` exactly as today
    ///   (`.changed` semantics, zero vault writes) → `.selected`; no
    ///   consent needed (pinned: any folder name with the structure simply
    ///   falls out of `.valid`).
    /// - Structure missing + `consent == true` → ONLY the missing dirs
    ///   scaffolded (the same helper as the create path), then stored like
    ///   a normal selection → `.scaffolded`.
    /// - Structure missing + `consent == false` → `.cancelled`: nothing on
    ///   disk modified, path NOT stored, the app stays `.notConfigured`.
    /// - `.nameCollision` → `.nameCollision` (typed inline error; nothing
    ///   modified; no scaffold offer).
    ///
    /// The refusal chain runs first (defensive parity with
    /// `setVaultPath`); nothing is touched on refusal. A mid-scaffold I/O
    /// failure (not a user decision) throws — the path stays unstored.
    /// Note the picked URL is used EXACTLY as picked — no re-sanitization
    /// (the folder already exists on disk; re-deriving its name through the
    /// create-path sanitizer could redirect the operation to a new folder).
    @discardableResult
    public func selectExistingVault(
        at url: URL, scaffoldMissingWithConsent consent: Bool
    ) async throws -> ExistingVaultOutcome {
        if isVaultLocationChangeRefused { return .refusedWhileSessionActive }

        let validation = VaultStructureValidator.validate(at: url)
        switch validation {
        case .valid:
            // Used as-is via setVaultPath exactly as today (issue #26 pins
            // `.changed` semantics here); the pre-check above already
            // refused nothing, and the chain was checked — the mapping is
            // defensive only.
            switch await setVaultPath(to: url) {
            case .changed:
                return .selected(url)
            case .refusedWhileSessionActive:
                return .refusedWhileSessionActive
            }
        case .nameCollision:
            return .nameCollision(url)
        case .missingTasks, .missingLogs, .bothMissing:
            guard consent else { return .cancelled(url) }
            // Scaffold ONLY what this re-validation found missing — the
            // one implementation shared with the create path (pinned).
            try VaultScaffolder.scaffoldMissingDirectories(at: url, validation: validation)
            await applyVaultLocation(url)
            return .scaffolded(url)
        }
    }

    // MARK: - Recovery surfacing (#13 → #20/#22 hand-off, closed by #36)

    /// Runs the #13 recovery decision over the persisted snapshot and
    /// surfaces the pending resume-or-discard state when one is present —
    /// now ALSO the phase swap (issue #36): surfacing is the ONE entry to
    /// the app shell's single prompt presentation, so the prompt appears on
    /// every launch path that has a pending snapshot (normal launch,
    /// quit-with-running-session, crash recovery — all converge on
    /// `bootstrap()`).
    private func surfaceRecoveryIfSnapshotPresent() async {
        let outcome = Result { try persistence.load() }
        switch ActiveSessionRecovery.decide(outcome) {
        case .resume(let snapshot):
            pendingSessionRecovery = snapshot
            // Issue #36: the display context is resolved ONCE at surfacing —
            // the vault reload just above refreshed the inventory, so the
            // lookup answers with current titles; unknown ID → the generic
            // wording (the session itself stays fully restorable: the engine
            // carries its own task ID).
            let context = await recoveryContext(for: snapshot)
            appPhase = .recoveryPrompt(snapshot, context)
        case .idle:
            break
        case .corruptSnapshot:
            // Already quarantined by the persistence layer; the snapshot is
            // treated as absent per the #13 contract. Nothing is lost.
            break
        }
    }

    /// The prompt's generic wording for a snapshot whose task ID is no
    /// longer resolvable in the vault (issue #36 — "unknown ID → generic
    /// wording"; public so the view and tests assert the exact string).
    public static let recoveredSessionGenericTitle = "Recovered session"

    /// Resolves the display context for a recovered snapshot (issue #36):
    /// the #19 lookup shape (a subtask at any depth inherits the parent
    /// task's project/categories, PRD §5.4; a top-level task shows its own
    /// fields) — `.notFound`, or no configured vault, resolves to the
    /// generic-wording context. Pure display resolution: nothing here
    /// touches the session itself.
    private func recoveryContext(
        for snapshot: ActiveSessionSnapshot
    ) async -> SessionContext {
        let generic = SessionContext(
            taskID: snapshot.taskID,
            title: Self.recoveredSessionGenericTitle,
            parentTaskTitle: nil, project: nil, categories: [])
        guard let store = vaultStore else { return generic }
        switch await store.lookup(snapshot.taskID) {
        case .task(let task):
            return SessionContext(
                taskID: task.id, title: task.title, parentTaskTitle: nil,
                project: task.project, categories: task.categories)
        case .subtask(let subtask, in: let parent):
            return SessionContext(
                taskID: subtask.id, title: subtask.title,
                parentTaskTitle: parent.title, project: parent.project,
                categories: parent.categories)
        case .notFound:
            return generic
        }
    }

    /// The "resume" choice of the pending resume-or-end state (the UI is
    /// the #36 recovery prompt): rehydrates the coordinator's engine from
    /// the pending snapshot via `ActiveSessionCoordinator.restore(from:)` —
    /// which also re-arms the autosave chain — and consumes the pending
    /// state. On a thrown error the pending state is retained, so the
    /// decision is not lost. Without a pending snapshot: the typed
    /// `.noPendingSession`.
    @discardableResult
    public func restorePendingSession() throws -> PendingRecoveryOutcome {
        guard let snapshot = pendingSessionRecovery else { return .noPendingSession }
        try coordinator.restore(from: snapshot)
        pendingSessionRecovery = nil
        sessionState = snapshot.isPaused ? .paused : .running
        // Issue #33: a recovery restore of an ALREADY-EXPIRED snapshot is
        // marked handled — the user explicitly resumed it, so the watcher
        // must not instantly re-end it (same rule as the #29 cancel-resume
        // of an auto-ended expiry); a restore below the duration watches
        // normally and will legitimately expire later in this process.
        expiryWatchState = expiryWatchState(forRestoredSnapshot: snapshot)
        // Issue #36: the prompt's Resume → the timer. The context resolved
        // at surfacing is reused so the prompt and the timer show the SAME
        // wording (the invariant is pending != nil ⟺ .recoveryPrompt is up;
        // the generic fallback covers a defensive mismatch — e.g. the API
        // called with a pending state surfaced before #36 — and never a
        // wrong title).
        if case .recoveryPrompt(_, let resolved) = appPhase,
            resolved.taskID == snapshot.taskID {
            appPhase = .timerView(resolved)
        } else {
            appPhase = .timerView(SessionContext(
                taskID: snapshot.taskID,
                title: Self.recoveredSessionGenericTitle,
                parentTaskTitle: nil, project: nil, categories: []))
        }
        return .restored
    }

    /// The "discard" choice of the pending resume-or-end state (the UI is
    /// the #36 recovery prompt's typed, destructive confirm — the session
    /// was never logged, so discarding is an honest §18 loss the user must
    /// confirm): clears the pending state **and** the on-disk snapshot, so
    /// the same snapshot cannot resurface on the next launch. On success
    /// the phase returns to `.tasksView` when the prompt phase was up (the
    /// invariant is pending != nil ⟺ `.recoveryPrompt` is up; the
    /// conditional keeps a direct API call in other phases honest) — Tasks
    /// stays, starts are allowed again. A failed on-disk clear is
    /// deliberately non-fatal and fail-safe: the file is left in place and
    /// will resurface on the next launch — losing the user's session data
    /// would be the unacceptable direction (PRD §18). Without a pending
    /// snapshot: the typed `.noPendingSession`.
    @discardableResult
    public func discardPendingSession() -> PendingRecoveryOutcome {
        guard pendingSessionRecovery != nil else { return .noPendingSession }
        pendingSessionRecovery = nil
        // Issue #36: the prompt's Discard → back to Tasks (starts allowed).
        if case .recoveryPrompt = appPhase { appPhase = .tasksView }
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
    /// 1–3, with #22's ending check and #23's break/choice checks added to
    /// the chain): session already active → end-of-session flow unresolved →
    /// break active → post-session choice → vault not configured → pending
    /// recovery unresolved. `nil` = all passed.
    private func startPrerequisitesRefusal() -> SessionStartRefusal? {
        if coordinator.isActive { return .sessionAlreadyActive }
        // Issue #22: after end() the engine is idle, so the active-session
        // guard above no longer covers the still-open end-of-session flow —
        // checked immediately after it in the pinned chain (§12.5: the form
        // must be completed before another work session can begin).
        if case .endingSession = appPhase { return .sessionEndingUnresolved }
        // Issue #23 (criterion 19), immediately after .sessionEndingUnresolved
        // in the pinned chain so both entry points inherit it: a running
        // break owns the app until the user ends it (PRD §14.3).
        if case .breakActive = appPhase { return .breakActive }
        // Issue #23 (criterion 20): the choice screen blocks the app —
        // defensive typed parity for the single-lifecycle rule.
        if case .postSessionChoice = appPhase { return .postSessionChoiceActive }
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
        // Issue #33: a fresh session arms the expiry watcher — the next
        // `evaluateSessionExpiry()` tick will alarm or auto-end when the
        // configured duration is reached.
        expiryWatchState = .watching
        sessionState = .running
        appPhase = .timerView(context)
        // A fresh session starts with no session number: the full TimerView
        // re-fetches its own #20 snapshot on appear (issue #21 criterion 2 —
        // a stale number from a previous session is never shown).
        sessionNumberToday = nil
        // Issue #34: the start just succeeded — record the session's
        // target for the session-start sheet's pre-selection (in-memory
        // only; survives end/submit/cancel, dies with the process).
        lastSessionTargetID = taskID
        return .started(context)
    }

    // MARK: - Mini mode (issue #21, PRD §10.2)

    /// Records the #20 session-number snapshot (issue #21 criterion 2):
    /// written by the full `TimerView`'s once-on-appear fetch (including an
    /// explicit `nil` on fetch failure — graceful omission), read by
    /// `MiniTimerView` with no refetch.
    public func recordSessionNumberToday(_ number: Int?) {
        sessionNumberToday = number
    }

    /// Collapse-to-mini (issue #21 criterion 3, PRD §10.2): explicitly flips
    /// the observable mini-mode flag on. The shell swaps content and the
    /// presentation controller compacts the same main window. Guards,
    /// documented: refuses when **no session is active** (compact mode only
    /// exists while a session is active, issue criterion 5) or the phase is
    /// not `.timerView` — a silent no-op either way, since the control that
    /// triggers this only exists on the active-session timer view. The
    /// session itself is untouched: same coordinator, same engine, same
    /// `.timerView(context)` phase.
    public func collapseToMiniTimer() {
        guard isSessionActive else { return }
        guard case .timerView = appPhase else { return }
        guard !isMiniTimerActive else { return }
        isMiniTimerActive = true
    }

    /// Restore-from-mini (issue #21 criterion 3): explicitly flips the
    /// mini-mode flag off. The phase
    /// stays `.timerView(context)` and the session lifecycle is untouched —
    /// the full timer display is restored by the same observable-driven
    /// sync. A typed no-op when not collapsed.
    public func restoreFromMiniTimer() {
        guard isMiniTimerActive else { return }
        isMiniTimerActive = false
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

    /// The confirm-End step of the end flow (issue #22, PRD §9.5 → §12;
    /// extended by issue #29): captures the end-instant snapshot FIRST — the
    /// coordinator's read-only `captureSnapshot()` passthrough, a pure engine
    /// read (after end the engine is idle and capture returns `nil`, so the
    /// order is pinned) — then runs the coordinator end (engine result + the
    /// #13 clear-on-end snapshot wipe — verified by the coordinator's
    /// contract, and the submission adds no snapshot and clears nothing),
    /// flips `sessionState` to `.idle` from the confirm instant, clears the
    /// mini-mode flag (normal presentation returns on an end **by any path**,
    /// issue #21 criterion 5) and the #20 session-number snapshot, and swaps
    /// the phase to `.endingSession(result, snapshot, context)` — the
    /// REQUIRED end-of-session modal over the timer (presented by the app
    /// shell; ending from mini restores the main window with the modal over
    /// it). The retained snapshot is what Cancel (#29) restores from; the
    /// ≈0 time between capture and end is absorbed by the restore re-anchor.
    /// Only `submitEndOfSession`, `cancelEndOfSession` (#29) and
    /// `discardEndOfSession` (#27) leave `.endingSession`.
    ///
    /// - Throws: `FocusSessionError.noActiveSession` when there is no
    ///   `.timerView` phase to end (the End control only exists on the
    ///   active-session timer view, so this is a caller contract
    ///   violation — nothing was ended) or the engine's own end error.
    ///   The same idle condition is mirrored on the capture itself (a nil
    ///   snapshot with an open `.timerView` phase is the same contract
    ///   violation — thrown, never a silent nil payload).
    @discardableResult
    public func endSession() throws -> FocusSessionResult {
        guard case .timerView(let context) = appPhase else {
            throw FocusSessionError.noActiveSession
        }
        // Issue #33: stop the alarm defensively — a manual End requires the
        // app focused (the alarm auto-ends on focus-back), so the alarm is
        // normally already stopped; this covers the sub-second race where
        // the confirm lands before the next watcher tick. The watcher is
        // retired with the lifecycle (fresh sessions re-arm it).
        expiryAlarm.stop()
        // Issue #29 pinned capture order: BEFORE coordinator.end() — after
        // end the engine is idle and capture returns nil. `FocusSessionResult`
        // carries neither the pause state nor the configured duration, so
        // the snapshot is the only faithful restore source (rejected
        // alternatives documented on `AppPhase.endingSession`).
        guard let snapshot = coordinator.captureSnapshot() else {
            throw FocusSessionError.noActiveSession
        }
        let result = try coordinator.end()
        sessionState = .idle
        isMiniTimerActive = false
        sessionNumberToday = nil
        expiryWatchState = .idle
        appPhase = .endingSession(result, snapshot, context)
        return result
    }

    // MARK: - End-of-session submission (issue #22, PRD §12, §13, §6.5, §18)

    /// The typed outcome of the end-of-session submission (issue #22
    /// criterion 13; `Equatable` for exact-case assertions — house style).
    /// Internal because the submission takes the internal pure form state
    /// (the #16/#17 house pattern — form states stay module-private).
    ///
    /// **Atomicity reality, documented honestly:** log append + task
    /// completion are TWO writes (the day file + the task file);
    /// atomicity across them is NOT claimed. The pinned ordering is log
    /// first (§18: no silent loss of session data), then completion.
    ///
    /// **Exit routing (issue #23, PRD §14.1):** the two outcomes that leave
    /// the flow — `.success` and `.completionFailedAfterLog` — stop at the
    /// `.postSessionChoice` phase (Start Next Session / Take Break) instead
    /// of landing directly on `.tasksView`; the partial outcome carries its
    /// completion failure in the phase payload so the choice view surfaces
    /// the #22 warning inline. `.logAppendFailed` keeps the modal up for
    /// retry and shows NO choice.
    enum EndOfSessionOutcome: Equatable, Sendable {
        /// The log was written and the completion (when Yes) applied; the
        /// flow stops at the #23 post-session choice (the ending state is
        /// cleared).
        case success
        /// The log append failed — nothing was written (validation runs
        /// before I/O and the append itself is atomic). The ending state is
        /// RETAINED (the phase stays `.endingSession`, the modal stays up)
        /// for retry: the in-memory result is the only copy of the session
        /// (the snapshot was cleared at confirm), so dropping it would
        /// violate §18.
        case logAppendFailed(DailyLogError)
        /// Typed partial failure: the session IS logged, the task status is
        /// NOT updated. The ending state is cleared and the flow stops at
        /// the #23 post-session choice (which surfaces this failure's #22
        /// guidance inline — complete the task manually from the task
        /// list). No silent divergence either way.
        case completionFailedAfterLog(VaultStoreError)
    }

    /// The REQUIRED submission of the end-of-session modal (issue #22,
    /// §12.5), in the pinned order:
    ///
    /// 1. **Compose** the §13 log purely via
    ///    `EndOfSessionFormState.makeLog(from:)` — the seven timing fields
    ///    from the retained result; `focus_rating`/`energy_rating` from the
    ///    modal; `task_completed` from Yes/No; `notes` nil-when-trimmed-empty.
    /// 2. **LOG FIRST** (§18): `DailyLogStore.appendSession` to the
    ///    session's END day — `logDay(forEndedAt:)`, the local calendar day
    ///    of `ended_at` (a midnight-spanning session logs to its end day).
    /// 3. **Completion** (§6.5) — only on Yes: `VaultStore.complete(taskID)`
    ///    (recursive parent bubble applied with ONE whole-file rewrite)
    ///    followed by the usual synced-inventory mirror. On No: nothing.
    /// 4. **Phase → `.postSessionChoice`** (issue #23): the ending state is
    ///    cleared and the explicit Start Next Session / Take Break choice is
    ///    shown (the `.completionFailedAfterLog` payload carries the
    ///    completion failure for the inline #22 warning).
    ///
    /// Failures surface as the typed `EndOfSessionOutcome` cases exactly as
    /// documented there; only errors outside the stores' typed contracts
    /// (none per those contracts) propagate as thrown errors.
    ///
    /// - Returns: `nil` for a caller contract violation — no `.endingSession`
    ///   phase, an incomplete form, or a missing store. None of these can
    ///   arise from the pinned call site (the sheet exists only while
    ///   ending, its submit button is enabled only on a complete form, and
    ///   the stores are provably non-nil while ending because a session
    ///   requires a configured vault to start and `setVaultPath` refuses
    ///   until the flow closes) — surfaced as `nil`, deliberately not a
    ///   masked outcome case.
    @discardableResult
    func submitEndOfSession(
        _ form: EndOfSessionFormState
    ) async throws -> EndOfSessionOutcome? {
        guard case .endingSession(let result, _, _) = appPhase, form.isSubmittable,
            let store = vaultStore, let logs = dailyLogStore
        else {
            return nil
        }

        // Step 1: pure composition.
        let log = form.makeLog(from: result)

        // Step 2: LOG FIRST, to the END day (§13 daily files).
        do {
            try await logs.appendSession(
                log, to: Self.logDay(forEndedAt: result.endedAt))
        } catch let error as DailyLogError {
            // Nothing written; the ending state is retained and the modal
            // stays up for retry (see `EndOfSessionOutcome`).
            return .logAppendFailed(error)
        }

        // Step 3: the §6.5 completion — Yes only. A refused/no-op decision
        // (e.g. an already-Done target) writes nothing and is still a
        // successful submission.
        if form.completedChoice == .yes {
            let outcome: StatusTransition.Outcome
            do {
                outcome = try await store.complete(result.taskID)
            } catch let error as VaultStoreError {
                // The documented partial outcome: logged, not completed.
                // Issue #23 routes the flow's exit to the post-session
                // choice, carrying the failure for the inline #22 warning.
                appPhase = .postSessionChoice(completionFailure: error)
                return .completionFailedAfterLog(error)
            }
            await mirrorSyncedInventory(from: store)
            // Issue #32: when the change set contains the owning top-level
            // task, its whole tree just moved into Done and — with the §8.3
            // filter off — out of the visible list. Surface the move as a
            // transient notice so it is never inexplicable. A subtask
            // completion that leaves its top-level owner active changes
            // nothing discoverable and sets no notice; a no-op decision
            // (`.transitioned([])`, e.g. an already-Done target) moved
            // nothing either.
            if case .transitioned(let changed) = outcome, !changed.isEmpty,
                let owner = tasks.first(where: { changed.contains($0.id) })
            {
                completionNotice = CompletionNotice(taskTitle: owner.title)
            }
        }

        // Step 4: the ending state is cleared — including the #29 retained
        // snapshot, which is DROPPED here (never restorable once logged);
        // the flow stops at the #23 post-session choice (Start Next Session
        // / Take Break — nothing auto-starts). The #33 watcher is retired
        // with the lifecycle.
        expiryWatchState = .idle
        appPhase = .postSessionChoice(completionFailure: nil)
        return .success
    }

    /// Dismisses the transient completion notice (issue #32) — the banner's
    /// manual dismiss action; the Tasks view's auto-expiry calls this too.
    /// A typed no-op when no notice is showing.
    public func dismissCompletionNotice() {
        completionNotice = nil
    }

    /// The day file a session logs into (issue #22 criterion 10, PRD §13):
    /// the **local calendar day of `ended_at`** — a session spanning
    /// midnight logs to its END day. Pure (no I/O), pinned here so the
    /// selection cannot drift between the model and tests; the store
    /// resolves the returned instant to `Logs/YYYY-MM-DD.md` through the
    /// same `DailyLogDay` convention every other date parameter uses.
    public nonisolated static func logDay(
        forEndedAt endedAt: Date, calendar: Calendar = .current
    ) -> Date {
        calendar.startOfDay(for: endedAt)
    }

    /// The #27 escape hatch for a `.logAppendFailed`-trapped modal: drops
    /// the whole unsubmitted end-of-session flow — the in-memory result is
    /// DISCARDED (together with the #29 retained snapshot, so nothing is
    /// restorable afterwards) and the phase moves to `.tasksView`. Nothing
    /// is written to any log (no day file is read, created or modified).
    ///
    /// **Honest §18 loss, documented inline (and surfaced in the modal's
    /// typed confirm):** the in-memory result is the ONLY copy of the
    /// session — the snapshot was already cleared at the confirm-End step —
    /// so discarding permanently loses the unsubmitted session. That is the
    /// user's explicit, confirmed choice (the modal offers this only after
    /// a failed append, destructive-styled behind a confirmation dialog),
    /// and it exists so the blocking modal can never trap: retry stays
    /// available, but a deterministic failure must not hold the app
    /// hostage. A typed no-op outside `.endingSession` (the control only
    /// exists in the failing modal — the `chooseStartNextSession` guard
    /// precedent).
    func discardEndOfSession() {
        guard case .endingSession = appPhase else { return }
        // Issue #33: retire the watcher with the lifecycle (hygiene — the
        // engine is already idle, so the tick would no-op anyway).
        expiryWatchState = .idle
        appPhase = .tasksView
    }

    // MARK: - Cancel on the end-of-session modal (issue #29, un-ending)

    /// The typed outcome of the modal Cancel (issue #29; `Equatable` for
    /// exact-case assertions — house style).
    public enum EndOfSessionCancelOutcome: Equatable, Sendable {
        /// The session was restored from the captured end-instant snapshot:
        /// the engine is live again (same session, re-anchored at the
        /// restore instant) and the phase is `.timerView(context)`.
        case restored
        /// Typed no-op outside `.endingSession` (the control only exists in
        /// the modal — the `chooseStartNextSession` guard precedent). Also
        /// the outcome after the snapshot was dropped by a submission or a
        /// #27 discard: the phase has left `.endingSession`, so there is
        /// nothing to cancel and nothing restorable.
        case noEndingSession
    }

    /// The modal's **Cancel** (issue #29): un-ends the session — the
    /// retained `FocusSessionResult` is discarded AS A LOG (nothing is ever
    /// appended by this path) and the session is restored from the
    /// end-instant snapshot retained in the phase payload, reusing the #13
    /// `restore(from:)` path UNCHANGED (not a fork): same `session_id`, same
    /// `started_at`, same second-precision accumulators, same pause count,
    /// same configured duration, same phase.
    ///
    /// **Pinned ordering (issue #29 — no window where both guards are
    /// passable):** restore FIRST → `sessionState` update → phase swap.
    /// While `.endingSession` is up, starts refuse via
    /// `.sessionEndingUnresolved` (engine idle, phase guard); the restore
    /// re-opens the engine BEFORE the phase leaves `.endingSession`, so
    /// after Cancel starts refuse via the ordinary already-active-session
    /// guard (`.sessionAlreadyActive`) — there is no instant where the
    /// phase has left `.endingSession` while the engine is still idle.
    ///
    /// **Modal-time mechanic (pinned, consistent with #12's segment
    /// semantics and the UI's Pause/Resume state):** the captured phase is
    /// restored FAITHFULLY.
    /// - Running-at-end → restored RUNNING: `restore` re-anchors the open
    ///   run segment at the restore instant, so the modal time counts as
    ///   NOTHING (neither focused nor paused) and the clock continues
    ///   growing focused time from there.
    /// - Paused-at-end → restored PAUSED (the UI shows Resume): the open
    ///   pause segment re-anchors at the restore instant, so the time until
    ///   the user resumes lands in PAUSED time per #12's open-pause-segment
    ///   semantics — NEVER focused. (Rejected: always restore running —
    ///   contradicts the captured phase and the button state.)
    /// Both paths satisfy the pinned invariant: time spent on the modal
    /// never counts as focused.
    ///
    /// **Side effects (per the #13 cadence, not forked):** the coordinator's
    /// `restore` re-arms the autosave chain; the snapshot is re-persisted by
    /// the cadence itself (the next tick, ≤ 1 autosave interval after the
    /// restore — the same honest-loss bound as any other save point).
    ///
    /// **Not re-fetched (already correct, documented):** `sessionNumberToday`
    /// is deliberately untouched — `endSession()` cleared it, and the #21
    /// view-driven once-on-appear fetch of the restored `.timerView` owns
    /// the refresh; no model-side fetch exists on this path.
    ///
    /// **Mini mode (engineer's choice, documented):** Cancel always lands on
    /// the FULL timer — the pre-`endSession()` `isMiniTimerActive` value is
    /// not retained or restored (`endSession()` cleared the flag and the
    /// modal is a full-window affair; ending from mini already restored the
    /// main window). The user re-collapses from the full timer if desired;
    /// silently re-collapsing after a modal interaction would surprise.
    ///
    /// - Throws: only `restore(from:)`'s `.sessionAlreadyActive` — impossible
    ///   here (the engine has been idle since the confirm-End), but surfaced,
    ///   never swallowed; on a throw nothing changed (the modal stays up for
    ///   retry, the phase is untouched).
    /// - Returns: `nil` is never returned (non-optional); the typed
    ///   `.noEndingSession` covers the no-modal states.
    @discardableResult
    public func cancelEndOfSession() throws -> EndOfSessionCancelOutcome {
        guard case .endingSession(_, let snapshot, let context) = appPhase else {
            return .noEndingSession
        }
        // Pinned step 1: restore BEFORE any state change — the engine is
        // live again from this instant (re-anchored at now), so no window
        // exists where the flow is resolvable-but-idle.
        try coordinator.restore(from: snapshot)
        // Pinned step 2: the observable session state follows the captured
        // phase — faithful restoration (running-at-end → running;
        // paused-at-end → paused).
        sessionState = snapshot.isPaused ? .paused : .running
        // Issue #33: the expiry watch follows the restored state — a
        // cancel-resume of an auto-ended (expired) session is marked
        // HANDLED (no instant re-alarm/re-end of what the user just chose
        // to continue); a cancel-resume of a non-expired manual end
        // watches again and will legitimately expire later.
        expiryWatchState = expiryWatchState(forRestoredSnapshot: snapshot)
        // Pinned step 3: the phase swap drops the retained ending state
        // (result + snapshot) and returns to the timer.
        appPhase = .timerView(context)
        return .restored
    }

    // MARK: - Expiry alarm + focus-back auto-end (issue #33)

    /// The per-session expiry-watch state (issue #33). Private by design —
    /// it is the model's internal latch ensuring the expiry action (alarm
    /// or auto-end) fires EXACTLY ONCE per session lifecycle, and that a
    /// cancel-resumed (or recovery-restored) expired session is not
    /// instantly re-ended by the next ~1 s watcher tick.
    private enum ExpiryWatchState {
        /// No session lifecycle is open.
        case idle
        /// A session is live and its expiry is still ahead: the watcher
        /// acts on it (alarm / auto-end) when `isExpired` flips true.
        case watching
        /// The expiry was already handled for this lifecycle: the alarm
        /// fired (focus-back auto-end pending) or the auto-end ran, or the
        /// session was restored from an already-expired snapshot
        /// (cancel-resume / recovery). Fresh sessions re-arm via
        /// `beginEngineSession`.
        case handled
    }

    private var expiryWatchState: ExpiryWatchState = .idle

    /// The watch state a RESTORED session resumes with (issue #33): a
    /// snapshot already at or past its configured duration is `.handled` —
    /// its expiry predates the restore and the user has explicitly chosen
    /// to continue the session (re-firing would instantly re-end what they
    /// just restored); a snapshot still below the duration watches again
    /// (it will legitimately expire later in this process).
    private func expiryWatchState(
        forRestoredSnapshot snapshot: ActiveSessionSnapshot
    ) -> ExpiryWatchState {
        snapshot.accumulatedFocusedSeconds >= snapshot.duration
            ? .handled : .watching
    }

    /// The ~1 s expiry-watch tick (issue #33): called by the timer views'
    /// watch tasks (`TimerView`/`MiniTimerView`) while a session is active,
    /// and directly by tests. Idempotent, cheap, and safe to call at any
    /// rate — everything is guarded:
    ///
    /// 1. The watch state must be `.watching` (not handled/idle) — this is
    ///    the exactly-once latch: while the alarm runs the user keeps
    ///    ignoring, repeated ticks re-deliver nothing (no alarm restarts,
    ///    no beep pile-up).
    /// 2. A session must be live and `isExpired` true at the shared clock's
    ///    current reading — the same pure engine predicate the countdown
    ///    displays (detection granularity is therefore ~1 s, the tick
    ///    cadence; the session state itself is untouched — the engine keeps
    ///    its own honest accumulators).
    /// 3. The decision (pinned): app ACTIVE → the alarm is pointless, go
    ///    straight to `autoEndExpiredSession()`; app UNFOCUSED → start the
    ///    alarm (first restoring the full timer from mini mode — the shake
    ///    is a full-window affordance) and wait for focus-back, which the
    ///    controller delivers via `onFocusBack` → auto-end.
    public func evaluateSessionExpiry() {
        guard expiryWatchState == .watching else { return }
        guard coordinator.isActive else { return }
        guard coordinator.isExpired(at: sessionClock.monotonicSeconds) else {
            return
        }
        // Latch FIRST: from this instant the expiry is handled for this
        // lifecycle, whatever branch runs below.
        expiryWatchState = .handled
        if expiryAlarm.isAppActive {
            // Expiry while focused: no alarm needed (pinned) — straight to
            // the auto-end + modal.
            autoEndExpiredSession()
        } else {
            // Expiry while unfocused: alarm until the user focuses back.
            if isMiniTimerActive { restoreFromMiniTimer() }
            expiryAlarm.start()
        }
    }

    /// The auto-end of an expired session (issue #33) — the shared tail of
    /// BOTH expiry paths (focus-back during the alarm, and expiry-while-
    /// active). Ends the session at the EXPIRY instant and enters the
    /// standard #22 end-of-session modal WITHOUT the End/Cancel confirm
    /// (user-pinned: the confirm remains for manual End only):
    ///
    /// 1. The alarm is stopped first (no-op when it never ran — the
    ///    expiry-while-active path), so the shake flag and beeps end before
    ///    any ending work.
    /// 2. The end-time snapshot is captured BEFORE `coordinator.end()` (the
    ///    #29 pinned capture order — after end the engine is idle and
    ///    capture returns nil).
    /// 3. `coordinator.end()` runs (engine result + the #13 clear-on-end
    ///    snapshot wipe — the session completed, so clearing is right).
    /// 4. **The composition-layer amendment (engine UNCHANGED, like #27):**
    ///    the retained `FocusSessionResult` is composed with
    ///    `endedAt = startedAt + duration` (the expiry instant — no overrun
    ///    counted, amending #12's accumulate-past-expiry) and
    ///    `focusedDuration` = the configured duration in whole minutes (the
    ///    #12 rounding rule via `EndOfSessionFormState.nearestMinute`), so
    ///    the modal shows the honest "N min focused". The #27 span formula
    ///    in `makeLog` then reconciles EXACTLY: the wall span IS the
    ///    duration, so `focused + paused == duration` minutes and any
    ///    post-expiry time (which the engine kept accumulating) is excluded
    ///    by the span, never logged as overrun. `pausedDuration` carries
    ///    the engine's value — the pre-expiry pauses (exact on the
    ///    focus-back path, where no pause click can be delivered while the
    ///    app is unfocused; on the expiry-while-active path the watcher
    ///    fires within ~1 s, bounding any post-expiry drift to that
    ///    sub-second window — documented honest bound).
    /// 5. The `.endingSession` snapshot payload is the EXPIRY-INSTANT
    ///    state, not the end-time one: focused accumulators pinned to
    ///    exactly `duration` (the definition of expiry), pre-expiry paused
    ///    seconds, `pauseCount` as of end, and `isPaused == false` (expiry
    ///    is only reachable while running — focused freezes while paused).
    ///    This is what Cancel (#29) restores: the session AT its expiry
    ///    state, consistent with `ended_at = expiry` — further time then
    ///    counts as focused and the next end reconciles again via #27.
    /// 6. The standard end-flow state updates (session idle, mini flag and
    ///    the #20 session-number snapshot cleared) and the phase swap —
    ///    the app shell presents the modal over the timer (ONE path).
    ///
    /// Every guard failure (`no .timerView`, idle engine) is a caller
    /// contract violation — the only call sites are the watcher and the
    /// focus-back handler, both of which run while the session is live and
    /// on the timer — so failures are silent no-ops rather than thrown
    /// errors (there is no UI to surface them to on these paths).
    private func autoEndExpiredSession() {
        // Stop the alarm first (spec order; no-op when it never ran).
        expiryAlarm.stop()
        guard case .timerView(let context) = appPhase else { return }
        // #29 pinned capture order: BEFORE coordinator.end().
        guard let endSnapshot = coordinator.captureSnapshot() else { return }
        let raw: FocusSessionResult
        do {
            raw = try coordinator.end()
        } catch {
            // Unreachable (the capture above proved a live lifecycle) —
            // fail closed without touching anything.
            return
        }
        let corrected = FocusSessionResult(
            sessionID: raw.sessionID,
            taskID: raw.taskID,
            startedAt: raw.startedAt,
            endedAt: raw.startedAt.addingTimeInterval(endSnapshot.duration),
            focusedDuration: EndOfSessionFormState.nearestMinute(
                fromSeconds: endSnapshot.duration),
            pauseCount: raw.pauseCount,
            pausedDuration: raw.pausedDuration)
        let snapshot = ActiveSessionSnapshot(
            sessionID: endSnapshot.sessionID,
            taskID: endSnapshot.taskID,
            duration: endSnapshot.duration,
            startedAt: endSnapshot.startedAt,
            accumulatedFocusedSeconds: endSnapshot.duration,
            accumulatedPausedSeconds: endSnapshot.accumulatedPausedSeconds,
            pauseCount: endSnapshot.pauseCount,
            isPaused: false,
            segmentStartMonotonic: endSnapshot.segmentStartMonotonic)
        sessionState = .idle
        isMiniTimerActive = false
        sessionNumberToday = nil
        appPhase = .endingSession(corrected, snapshot, context)
    }

    // MARK: - Break flow (issue #23, PRD §14)

    /// The typed outcome of ending a break (issue #23 criterion 18;
    /// `Equatable` for exact-case assertions — house style).
    ///
    /// **Non-blocking by pinned design (documented divergence from the
    /// session flow's retry-in-place, #22):** a log failure does NOT trap
    /// the break UX — a small warning is surfaced
    /// (`pendingBreakLogWarning`) and the flow continues. Rationale: the
    /// break is transient and in-memory only (nothing is retained to
    /// retry with — the engine result and the composed log are the only
    /// copies, both dropped with the flow), `duration` is the single
    /// field of record, and a lost break log is the accepted, stated
    /// loss. The session flow retains its result because it is the ONLY
    /// copy of the session (§18); a break has no such standing.
    ///
    /// Exit routing (issue #34, amending #23): BOTH outcomes land on the
    /// `.sessionStart` phase — the session-start sheet opens directly
    /// (was: `.tasksView`).
    public enum BreakLogOutcome: Equatable, Sendable {
        /// The break was logged to its END day file; the phase is
        /// `.sessionStart` (#34).
        case logged(BreakLog)
        /// The append failed — nothing was written (validation runs before
        /// I/O and the append is atomic). NON-BLOCKING: the warning is
        /// surfaced and the flow still continues to `.sessionStart` (#34;
        /// see the type documentation).
        case logFailed(BreakLog, DailyLogError)
    }

    /// The live break engine, or nil when no break is running. The engine is
    /// a value type; the model owns the one live instance (same shape as the
    /// coordinator's session engine, minus the coordinator — there is no
    /// autosave, no snapshot, no recovery: **breaks are NOT persisted**
    /// (#13 grooming note / PRD §14), so quitting the app mid-break loses
    /// the break and logs nothing — the documented honest loss).
    private var breakEngine: BreakTimerEngine?

    /// The small non-blocking warning surfaced after a break-log append
    /// failure (issue #23 criterion 18): rendered by the app shell as a
    /// small banner; the flow continues to `.sessionStart` either way
    /// (#34 amendment). Cleared by the next `takeBreak` (a fresh break
    /// context) and by the next successful `endBreak`.
    public private(set) var pendingBreakLogWarning: String?

    /// Whether a break is currently running (the `.breakActive` phase).
    public var isBreakActive: Bool { breakEngine != nil }

    /// The configured duration of the active break in seconds (nil when no
    /// break). Fixed at `takeBreak` — no mid-break reconfiguration (§14.2).
    public var breakDurationSeconds: TimeInterval? {
        breakEngine?.configuredDurationSeconds
    }

    /// See `BreakTimerEngine.remainingSeconds(at:)`, evaluated at the shared
    /// clock's current monotonic reading. nil when no break. Time-derived:
    /// not reactive on its own — the break view's `TimelineView(.periodic)`
    /// tick supplies the re-render (the #20/#21 pattern).
    public var breakRemainingSeconds: Int? {
        breakEngine?.remainingSeconds(at: sessionClock.monotonicSeconds)
    }

    /// See `BreakTimerEngine.progressFraction(at:)`. 0 when no break.
    public var breakProgressFraction: Double {
        breakEngine?.progressFraction(at: sessionClock.monotonicSeconds) ?? 0
    }

    /// The observable break-expired state (issue #23 criterion 15): pure
    /// time derivation like `isSessionExpired` — false when no break. The
    /// break view's `TimelineView(.periodic)` tick re-reads it every second
    /// and surfaces the in-app notification banner when it flips true (no
    /// `UNUserNotificationCenter`, no auto-dismiss, no auto-start).
    public var isBreakExpired: Bool {
        breakEngine?.isExpired(at: sessionClock.monotonicSeconds) ?? false
    }

    /// Take Break (issue #23 criterion 5, PRD §14.2): starts the break
    /// countdown with the duration configured at the choice step (default 5
    /// minutes) and swaps the phase to `.breakActive`. Configuration happens
    /// before start only; no mid-break reconfiguration.
    ///
    /// - Throws: `BreakTimerError.breakAlreadyActive` — unreachable from the
    ///   pinned call site (the control exists only on the choice view, where
    ///   no break can be running); surfaced, never swallowed.
    public func takeBreak(
        duration: TimeInterval = BreakTimerEngine.defaultDurationSeconds
    ) throws {
        var engine = BreakTimerEngine(clock: sessionClock)
        try engine.start(duration: duration)
        breakEngine = engine
        pendingBreakLogWarning = nil
        appPhase = .breakActive
    }

    /// Start Next Session (issue #23 criterion 4; exit routing AMENDED
    /// by #34): swaps the phase to `.sessionStart` — the #19 session-start
    /// sheet opens DIRECTLY. This amends #23's pinned "return to
    /// `.tasksView`, no auto-open" decision at the user's request: the
    /// menu still shows and nothing auto-STARTS (the user still picks
    /// duration and confirms Start — §14.1's nothing-auto-starts holds;
    /// §20.7's "return to task/session selection" is now literal). The
    /// previous session's target pre-selects in the sheet when still
    /// eligible (#34, via `lastSessionTargetID`). A typed no-op outside
    /// the choice phase (the control only exists there, the
    /// `collapseToMiniTimer` guard precedent).
    public func chooseStartNextSession() {
        guard case .postSessionChoice = appPhase else { return }
        appPhase = .sessionStart
    }

    /// Cancels the phase-driven session-start sheet (issue #34): back to
    /// `.tasksView`. The sheet's Cancel button routes here (the phase owns
    /// the presentation — a plain `dismiss()` would leave the phase
    /// stranded); the tracking (`lastSessionTargetID`) is deliberately
    /// untouched — canceling the menu is not ending the loop. A typed
    /// no-op outside `.sessionStart` (the control only exists on the
    /// sheet presented for that phase — the `chooseStartNextSession`
    /// guard precedent).
    public func cancelSessionStart() {
        guard case .sessionStart = appPhase else { return }
        appPhase = .tasksView
    }

    /// Ends the active break — the ONE API behind the End-break-early
    /// control AND the post-expiry acknowledgment (issue #23 criteria
    /// 14/16; one behavior, two labels in the UI): the engine `end()`
    /// result composes the `BreakLog` (#11 type, actual — post-expiry
    /// clamped — duration), which is appended via `DailyLogStore
    /// .appendBreak` to the break's END day:
    /// `AppModel.logDay(forEndedAt:)` reused AS-IS (a break spanning
    /// midnight logs to its end day).
    ///
    /// Exit routing (issue #34, AMENDING #23's pinned `.tasksView` tail):
    /// the phase swaps to `.sessionStart` in EVERY outcome — the expiry
    /// acknowledgment, the early end, and the non-blocking log-failure
    /// path alike — so the loop lands directly on the session-start sheet
    /// with the last session's target pre-selected. The break UX still
    /// never traps: the append failure keeps its small warning
    /// (`pendingBreakLogWarning`) and the flow continues.
    ///
    /// - Returns: nil for a caller contract violation — no active break
    ///   (the controls only exist on the break view) — or the typed
    ///   `BreakLogOutcome` (`Equatable` for exact-case assertions).
    @discardableResult
    public func endBreak() async -> BreakLogOutcome? {
        guard var engine = breakEngine, let logs = dailyLogStore else {
            // The stores are provably non-nil while a break runs (a break
            // starts only from the post-session choice, which only a
            // configured vault reaches, and `setVaultPath` refuses while
            // the break is up) — nil is a caller contract violation,
            // surfaced as nil, deliberately not a masked outcome case (the
            // #22 submission precedent).
            return nil
        }
        let result: BreakResult
        do {
            result = try engine.end()
        } catch {
            // Unreachable: `breakEngine` is non-nil exactly while the
            // engine's lifecycle is open (cleared below on every end).
            // Fail-closed rather than force-try.
            return nil
        }
        breakEngine = nil
        let log = BreakLog(
            breakID: result.breakID,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            duration: result.duration)
        let outcome: BreakLogOutcome
        do {
            try await logs.appendBreak(log, to: Self.logDay(forEndedAt: result.endedAt))
            outcome = .logged(log)
            pendingBreakLogWarning = nil
        } catch let dailyLogError as DailyLogError {
            // Non-blocking by pinned design: surface the small warning and
            // CONTINUE to `.tasksView` (documented divergence from #22's
            // retry-in-place — see `BreakLogOutcome`).
            pendingBreakLogWarning = dailyLogError.description
            outcome = .logFailed(log, dailyLogError)
        } catch {
            // Unreachable per DailyLogStore's contract (its append path
            // throws only `DailyLogError`) — but the break UX must never
            // trap and nothing is retained to retry with, so the flow
            // fails closed honestly: the description is surfaced as the
            // warning, the flow still continues to `.tasksView`, and no
            // masked `.logFailed` is invented for a shape the store cannot
            // produce.
            pendingBreakLogWarning = String(describing: error)
            // Issue #34: the break UX must never trap — the flow still
            // continues, now to the session-start sheet.
            appPhase = .sessionStart
            return nil
        }
        // Issue #34: both the logged and the non-blocking-failure
        // outcomes land on the session-start sheet (was: `.tasksView` —
        // #23's pinned tail, amended).
        appPhase = .sessionStart
        return outcome
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
