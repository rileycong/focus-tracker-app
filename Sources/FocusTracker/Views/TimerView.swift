import SwiftUI

/// The full-screen timer view (issue #20, PRD §10.1, §21): the screen the app
/// auto-switches to when a session starts — `FocusTrackerApp` swaps on
/// `appPhase == .timerView(SessionContext)` (wired by #19, verified here).
/// Dark, minimal, calm Microsoft-Clock-style layout with the countdown as the
/// single visual priority. Shows exactly (PRD §10.1): task title ("Parent ›
/// Child" for a subtask target), project, category chips, "Session N today"
/// for the linked task, the large shrinking circular countdown ring with the
/// big monospaced countdown inside it, the estimated finish time under the
/// ring, and Pause/Resume + End Session controls.
///
/// Deliberately NOT shown (pinned do-not-show list, PRD §10.1): elapsed time,
/// progress percentage, priority, effort, deadline, analytics, next-task
/// suggestions. The collapse-to-mini control is #21's addition (below) — it
/// drives the always-on-top mini panel (`MiniTimerPanelController` +
/// `MiniTimerView`) and is absent from no other state.
///
/// # End flow (issue #22, PRD §9.5, §12)
/// The End Session control opens the minimal End/Cancel confirm (§9.5).
/// Cancel continues the session: no end, no modal. Confirming runs the
/// model's end flow — `AppModel.endSession()` ends the engine, retains the
/// `FocusSessionResult` and swaps the phase to `.endingSession` — which
/// opens the end-of-session modal over this timer. The modal is presented
/// by the app shell (the ONE phase-driven presentation path; this view
/// hosts no modal of its own), and only the required submission returns
/// the app to Tasks.
///
/// # Session number today (pinned semantics, issue #20 criterion 1; lifted
/// by #21)
/// Fetched **asynchronously once on view appear** via the #11 helper
/// `DailyLogStore.sessions(for:on:)` with the date from
/// `sessionClock.wallClockNow` (clock seam only) — a **snapshot, not
/// live-polled**: every later session on the same task re-appears this view
/// and re-fetches, so sessions ended earlier today on that task are naturally
/// included (PRD §10.1 self-correction). On fetch failure (or no configured
/// vault) the session-number line is gracefully **omitted** rather than
/// disrupting the timer. #21 lifted the recorded value into
/// `AppModel.sessionNumberToday` so the mini view shows the same snapshot
/// with no refetch (issue #21 criterion 2); this view reads it back from the
/// model.
///
/// # Ticking (issue #20 criterion 3)
/// A `TimelineView(.periodic)` re-renders about once per second and derives
/// every displayed value via `TimerDisplayState.derive` from the engine's
/// pure functions through the `AppModel` passthroughs — nothing mutates the
/// engine. While paused the engine's paused accumulators freeze
/// `remainingSeconds`/`progressFraction`, so countdown and ring hold still
/// and resume ticking on resume (#12 semantics, verified in
/// `TimerDisplayTests`).
///
/// # Expiry (pinned #12 semantics, issue #20 criterion 7)
/// When remaining hits 0 the ring completes (the full `focusRingCompleted`
/// circle — the subtle completion state, #35's lighter red-family tint):
/// the arc geometry swaps to the full circle (0→1) via the pure
/// `TimerDisplay.ringArc` (regression-tested — `trim(from: 1, to: 1)`
/// would render an empty arc and the ring would vanish). The countdown reads
/// "0:00", and the session **stays
/// active until the user ends it** — no auto-end, no auto-modal; the End
/// confirm remains available. **Engineer's choice (documented): at expiry the
/// ETA line is omitted** — the estimated finish time has passed, and showing
/// a stale or perpetually-moving "now" would be noise; omission keeps the
/// screen calm (PRD §21).
///
/// # Ring color RED (issue #35, PRD §21)
/// The user asked for the focus ring in red: the ring strokes
/// `DesignTokens.focusRing` (a calm dark-theme red, documented on the
/// token) while running and `DesignTokens.focusRingCompleted` — a lighter
/// tint of the same red family — at expiry/completion. Legibility in the
/// enforced dark theme is pinned by the token-level `DesignTokensTests`
/// (full-arc and paused-dim contrast, completed lighter than running).
/// Deliberately unchanged: the BREAK ring keeps its blue
/// `statusColor(.inProgress)` + green `.done` completion (`BreakView` —
/// issue #35 changes only the focus rings), and the mini panel shows no
/// ring at all (pinned §11 content — see `MiniTimerView`).
///
/// The `SessionTimerPlaceholderView` this replaces was **deleted** (its
/// rationale was absorbed into the sections above); the real file is the
/// honest home and a reduced stub would only be a second thing to maintain.
///
/// # Expiry alarm + shake (issue #33, PRD §9.5)
/// When the app is UNFOCUSED at expiry the model starts the in-app alarm
/// (`AppModel.isExpiryAlarmActive` — repeated system beeps ~1×/s inside the
/// `ExpiryAlarmController`, the alarm's one AppKit seam) and this view
/// shakes the timer layout: a small horizontal wobble (`shakeAmplitude`,
/// deliberately subtle within the dark-calm language — the ring, count and
/// controls stay put visually; nothing flashes or screams). The shake is
/// driven purely by the observable flag via `.onChange` (a `repeatForever`
/// ease wobble while alarming, an ease-out settle on stop — including the
/// auto-end that follows focus-back). Expiry while the app IS focused never
/// alarms: the watcher tick auto-ends straight to the #22 modal.
///
/// The view also owns one half of the expiry DETECTION: a `.task` watch
/// loop calls `AppModel.evaluateSessionExpiry()` about once per second for
/// this view's lifetime (idempotent, guarded — it no-ops when no unexpired
/// watchable session is live, so it is harmless under `.endingSession`,
/// where this view re-renders beneath the modal). `MiniTimerView` runs the
/// same loop so mini mode is covered; detection is therefore within ~1 s of
/// `remainingSeconds` hitting 0 — the same cadence as the countdown itself.
struct TimerView: View {
    /// The running session's display context (resolved at start, issue #19).
    let context: AppModel.SessionContext
    /// The composition root — the same authoritative passthroughs
    /// (`sessionState`, `remainingSeconds`, `progressFraction`,
    /// `sessionClock`, `pauseSession`/`resumeSession`/`endSession`,
    /// `dailyLogStore`) every layer uses.
    let model: AppModel

    /// The shake offset while the #33 expiry alarm is active (see the type
    /// documentation): 0 at rest, `shakeAmplitude` at the wobble's edge.
    @State private var shakeOffset: CGFloat = 0
    /// The shake amplitude (issue #33): deliberately small — an attention
    /// wobble, not a seizure (the dark-calm language, PRD §21).
    private static let shakeAmplitude: CGFloat = 4

    @State private var showsEndConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            // Pinned sizing (issue #20 criterion 2): diameter ≈ min(w, h) * 0.6.
            let diameter = min(geometry.size.width, geometry.size.height) * 0.6
            VStack(spacing: DesignTokens.spacingL) {
                titleBlock
                if !context.categories.isEmpty {
                    categoryChips
                }
                if let number = model.sessionNumberToday {
                    Text("Session \(number) today")
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ringBlock(diameter: diameter)
                }
                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Issue #33: the shake rides the observable alarm flag — a
            // repeating ease wobble while alarming, a quick settle on stop
            // (the auto-end that follows focus-back). Applied to the whole
            // layout so the ring, countdown and controls wobble together;
            // subtle amplitude, no color/flash changes (dark-calm, §21).
            .offset(x: shakeOffset)
            .onChange(of: model.isExpiryAlarmActive) { _, alarming in
                if alarming {
                    withAnimation(
                        .easeInOut(duration: 0.09).repeatForever(autoreverses: true)
                    ) {
                        shakeOffset = Self.shakeAmplitude
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { shakeOffset = 0 }
                }
            }
        }
        .background(DesignTokens.background)
        .confirmationDialog(
            "End this session?",
            isPresented: $showsEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Session", role: .destructive, action: endSession)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The session ends now. A short wrap-up form opens before the app returns to the tasks."
            )
        }
        .task {
            // Under `.endingSession` (#22) this timer renders fresh beneath
            // the blocking modal; the session-number fetch is a
            // live-session concern (the snapshot was cleared at confirm) —
            // no refetch while the ending flow drives.
            if model.isSessionActive {
                await loadSessionNumber()
            }
        }
        .task {
            // The #33 expiry watch (issue #33): ~1 s ticks driving the
            // alarm/auto-end decision. Idempotent and fully guarded — it
            // no-ops whenever no unhandled expiry is pending, so it is
            // harmless under `.endingSession` (this view re-renders beneath
            // the modal there) and in every other phase. `MiniTimerView`
            // runs the same loop so the collapsed mini panel is covered
            // too.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.evaluateSessionExpiry()
            }
        }
    }

    // MARK: - Pieces (PRD §10.1 content, in order)

    /// The task title — "Parent › Child" for a subtask target, the plain
    /// title otherwise (as the placeholder showed).
    private var displayTitle: String {
        if let parent = context.parentTaskTitle {
            return "\(parent) › \(context.title)"
        }
        return context.title
    }

    private var titleBlock: some View {
        VStack(spacing: DesignTokens.spacingXS) {
            Text(displayTitle)
                .font(DesignTokens.titleFont)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.spacingL)
            // Project line — omitted entirely when nil (issue #20 criterion 1).
            if let project = context.project {
                Text(project.name)
                    .font(DesignTokens.statusGroupFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Category chips — hidden when empty; the same token pair the task
    /// rows use (`chipFont`/`chipBackground`).
    private var categoryChips: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            ForEach(context.categories, id: \.name) { category in
                Text(category.name)
                    .font(DesignTokens.chipFont)
                    .padding(.horizontal, DesignTokens.spacingS)
                    .padding(.vertical, DesignTokens.spacingXS)
                    .background(DesignTokens.chipBackground)
                    .cornerRadius(DesignTokens.cornerRadius)
            }
        }
    }

    /// The ring + countdown + ETA block, re-evaluated on every ~1 s tick of
    /// the enclosing `TimelineView` (pure derivation, no engine mutation).
    @ViewBuilder
    private func ringBlock(diameter: CGFloat) -> some View {
        let state = displayState()
        VStack(spacing: DesignTokens.spacingM) {
            ZStack {
                // Track.
                Circle()
                    .stroke(DesignTokens.divider, lineWidth: DesignTokens.ringLineWidth)
                // Remaining arc: from the clamped progress offset to 1 — the
                // ring shrinks as time passes (issue #20 criterion 2). At
                // expiry the geometry swaps to the FULL circle (0→1) so the
                // ring completes into the #35 completion red; the range is
                // the pure, regression-tested `TimerDisplay.ringArc` (a naive
                // trim(from: 1, to: 1) would render an empty, vanished arc).
                Circle()
                    .trim(from: state.ringArc.from, to: state.ringArc.to)
                    .stroke(
                        state.isExpired
                            ? DesignTokens.focusRingCompleted
                            : DesignTokens.focusRing,
                        style: StrokeStyle(
                            lineWidth: DesignTokens.ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Paused is visible subtly (engineer's choice, calm per
                    // §21): the arc dims; the countdown dims with it below.
                    .opacity(state.isPaused ? DesignTokens.pausedArcOpacity : 1)
                    .animation(DesignTokens.ringTickAnimation, value: state.ringArc)
                    .animation(DesignTokens.stateAnimation, value: state.isPaused)
                Text(state.countdownText)
                    .font(.system(
                        size: diameter * 0.18, weight: .thin, design: .monospaced))
                    .monospacedDigit()
                    .opacity(state.isPaused ? DesignTokens.pausedTextOpacity : 1)
                    .animation(DesignTokens.stateAnimation, value: state.isPaused)
            }
            .frame(width: diameter, height: diameter)
            // Estimated finish time under the ring; omitted at expiry
            // (engineer's choice, documented in the type documentation).
            if !state.isExpired, let eta = etaText(for: state) {
                Text("Ends at \(eta)")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.spacingM) {
            // Collapse-to-mini (issue #21 criterion 3, PRD §10.2): flips the
            // model's mini-mode flag; the observable-driven sync in
            // `FocusTrackerApp` shows the mini panel and `orderOut`s this
            // window (the pinned choice over `miniaturize`). `TimerView`
            // only exists while a session is active, so the control can
            // never appear while idle; `collapseToMiniTimer()` still guards
            // session-active (issue criterion 5).
            Button {
                model.collapseToMiniTimer()
            } label: {
                Label("Mini", systemImage: "pip.enter")
            }
            .buttonStyle(.bordered)
            .help("Collapse to the always-on-top mini timer")
            // Label swaps Pause ↔ Resume (issue #20 criterion 4); the paused
            // state itself is shown on the ring (dimming above).
            Button(displayState().isPaused ? "Resume" : "Pause") { togglePause() }
                .buttonStyle(.bordered)
            Button("End Session", role: .destructive) { showsEndConfirmation = true }
                .buttonStyle(.bordered)
        }
        .padding(.bottom, DesignTokens.spacingL)
    }

    // MARK: - Display derivation (pure, through the passthroughs)

    /// One tick's display state: the engine's pure functions at the current
    /// monotonic reading, through the `AppModel` passthroughs — read-only,
    /// nothing mutates the engine (issue #20 criterion 3).
    private func displayState() -> TimerDisplayState {
        TimerDisplayState.derive(
            remainingSeconds: model.remainingSeconds,
            progressFraction: model.progressFraction,
            isPaused: model.sessionState == .paused)
    }

    /// Wall clock (seam only) plus the remaining seconds, via the pure
    /// helper — the engine's clamped remaining keeps this honest.
    private func etaText(for state: TimerDisplayState) -> String? {
        TimerDisplay.etaText(
            remainingSeconds: state.remainingSeconds,
            now: model.sessionClock.wallClockNow)
    }

    // MARK: - Actions

    /// Pause/Resume via the coordinator passthroughs. The engine refuses
    /// double pauses / resume-while-running by contract; that cannot arise
    /// from the swapped label, so the typed refusal is dropped here (not a
    /// user decision — house style).
    private func togglePause() {
        if model.sessionState == .paused {
            try? model.resumeSession()
        } else {
            try? model.pauseSession()
        }
    }

    /// The confirm-End handler (issue #22): the same `AppModel` path the
    /// mini panel's End control calls. Ends the engine, retains the result
    /// and enters `.endingSession` — the app shell presents the
    /// end-of-session modal over this timer; submission returns to Tasks.
    /// The engine refuses a second end by contract; that cannot arise from
    /// the confirm (it exists only on the active-session timer), so the
    /// typed refusal is dropped here (not a user decision — house style).
    private func endSession() {
        guard model.isSessionActive else { return }
        _ = try? model.endSession()
    }

    /// The pinned snapshot fetch (issue #20 criterion 1; lifted by #21 into
    /// `AppModel.sessionNumberToday` so the mini view reuses the value with
    /// no refetch, issue #21 criterion 2): run once on view appear via the
    /// #11 `DailyLogStore.sessions(for:on:)` helper, dated by the session
    /// clock seam. Not live-polled — see the type documentation. Graceful
    /// degradation: no vault, or a fetch failure, records `nil` (line
    /// omitted) instead of disrupting the timer.
    private func loadSessionNumber() async {
        guard let store = model.dailyLogStore else {
            model.recordSessionNumberToday(nil)
            return
        }
        do {
            let sessions = try await store.sessions(
                for: context.taskID, on: model.sessionClock.wallClockNow)
            model.recordSessionNumberToday(
                TimerDisplay.sessionNumber(fromSessions: sessions))
        } catch {
            // Documented graceful degradation (see above): omit the line.
            model.recordSessionNumberToday(nil)
        }
    }
}
