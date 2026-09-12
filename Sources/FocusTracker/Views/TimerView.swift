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
/// suggestions. The collapse-to-mini control is also absent entirely (#21
/// adds it together with the mini panel — no dead UI here).
///
/// # Temporary End path (carried over from the deleted #19 placeholder)
/// Nothing is logged or classified here — the end-of-session flow is #22.
/// The End Session control opens a minimal End/Cancel confirm and, on
/// confirm, calls `AppModel.endSession()` and returns to `.tasksView` **with
/// the `FocusSessionResult` discarded** — no `Logs/` append and no log path
/// invented that #22 would have to undo. #22 replaces this with the
/// end-of-session modal + logging (marked inline at the confirm handler).
///
/// # Session number today (pinned semantics, issue #20 criterion 1)
/// Fetched **asynchronously once on view appear** via the #11 helper
/// `DailyLogStore.sessions(for:on:)` with the date from
/// `sessionClock.wallClockNow` (clock seam only) — a **snapshot, not
/// live-polled**: every later session on the same task re-appears this view
/// and re-fetches, so sessions ended earlier today on that task are naturally
/// included (PRD §10.1 self-correction). On fetch failure (or no configured
/// vault) the session-number line is gracefully **omitted** rather than
/// disrupting the timer.
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
/// When remaining hits 0 the ring completes (full "done" color — the subtle
/// completion state): the arc geometry swaps to the full circle (0→1) via the
/// pure `TimerDisplay.ringArc` (regression-tested — `trim(from: 1, to: 1)`
/// would render an empty arc and the ring would vanish). The countdown reads
/// "0:00", and the session **stays
/// active until the user ends it** — no auto-end, no auto-modal; the End
/// confirm remains available. **Engineer's choice (documented): at expiry the
/// ETA line is omitted** — the estimated finish time has passed, and showing
/// a stale or perpetually-moving "now" would be noise; omission keeps the
/// screen calm (PRD §21).
///
/// The `SessionTimerPlaceholderView` this replaces was **deleted** (its
/// temporary-End rationale moved here verbatim); the real file is the honest
/// home and a reduced stub would only be a second thing to remove in #22.
struct TimerView: View {
    /// The running session's display context (resolved at start, issue #19).
    let context: AppModel.SessionContext
    /// The composition root — the same authoritative passthroughs
    /// (`sessionState`, `remainingSeconds`, `progressFraction`,
    /// `sessionClock`, `pauseSession`/`resumeSession`/`endSession`,
    /// `dailyLogStore`) every layer uses.
    let model: AppModel

    /// Ring stroke width — substantial but calm (PRD §21).
    private static let ringLineWidth: CGFloat = 10

    @State private var sessionNumberToday: Int?
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
                if let number = sessionNumberToday {
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
            Text("The session ends and the app returns to the tasks.")
        }
        .task { await loadSessionNumber() }
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
                .font(.title2)
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
                    .stroke(DesignTokens.divider, lineWidth: Self.ringLineWidth)
                // Remaining arc: from the clamped progress offset to 1 — the
                // ring shrinks as time passes (issue #20 criterion 2). At
                // expiry the geometry swaps to the FULL circle (0→1) so the
                // ring completes into the subtle "done" color; the range is
                // the pure, regression-tested `TimerDisplay.ringArc` (a naive
                // trim(from: 1, to: 1) would render an empty, vanished arc).
                Circle()
                    .trim(from: state.ringArc.from, to: state.ringArc.to)
                    .stroke(
                        state.isExpired
                            ? DesignTokens.statusColor(.done)
                            : DesignTokens.statusColor(.inProgress),
                        style: StrokeStyle(
                            lineWidth: Self.ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Paused is visible subtly (engineer's choice, calm per
                    // §21): the arc dims; the countdown dims with it below.
                    .opacity(state.isPaused ? 0.45 : 1)
                    .animation(.linear(duration: 1), value: state.ringArc)
                    .animation(.easeInOut(duration: 0.35), value: state.isPaused)
                Text(state.countdownText)
                    .font(.system(
                        size: diameter * 0.18, weight: .thin, design: .monospaced))
                    .monospacedDigit()
                    .opacity(state.isPaused ? 0.55 : 1)
                    .animation(.easeInOut(duration: 0.35), value: state.isPaused)
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

    /// The **temporary** end path (issue #20 criterion 5 — #22 replaces it):
    /// confirm calls `AppModel.endSession()` and returns to `.tasksView`
    /// WITHOUT logging anything. The `FocusSessionResult` is discarded
    /// exactly as the deleted #19 placeholder documented — no log path is
    /// invented that #22 would have to undo. #22 replaces this with the
    /// end-of-session modal + logging.
    private func endSession() {
        guard model.isSessionActive else { return }
        _ = try? model.endSession()
    }

    /// The pinned snapshot fetch (issue #20 criterion 1): run once on view
    /// appear via the #11 `DailyLogStore.sessions(for:on:)` helper, dated by
    /// the session clock seam. Not live-polled — see the type documentation.
    /// Graceful degradation: no vault, or a fetch failure, leaves the line
    /// omitted (`sessionNumberToday == nil`) instead of disrupting the timer.
    private func loadSessionNumber() async {
        guard let store = model.dailyLogStore else { return }
        do {
            let sessions = try await store.sessions(
                for: context.taskID, on: model.sessionClock.wallClockNow)
            sessionNumberToday = TimerDisplay.sessionNumber(fromSessions: sessions)
        } catch {
            // Documented graceful degradation (see above): omit the line.
            sessionNumberToday = nil
        }
    }
}
