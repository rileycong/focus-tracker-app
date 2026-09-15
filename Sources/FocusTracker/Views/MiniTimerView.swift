import SwiftUI

/// The compact always-on-top mini timer (issue #21, PRD §11, §10.2, §21),
/// hosted inside the app's existing main window while it uses compact
/// always-on-top presentation. This file stays pure SwiftUI.
///
/// Shows EXACTLY the PRD §11 list: the **task title** ("Parent › Child"
/// resolution, identical to #20's `TimerView`), the **countdown** —
/// monospaced digits through the same #20 `TimerDisplayState.derive` /
/// `TimerDisplay.countdownText` helpers (`m:ss` / `h:mm:ss` / `0:00`) — the
/// **current session number for that task today**, a **Pause/Resume**
/// control, and an **End/Stop** control — plus a restore affordance (the
/// display area is click-to-restore, and the compact window background is
/// draggable).
///
/// Deliberately NOT shown (pinned do-not-show list, PRD §11 — checked
/// against the final UI): project, categories, metadata, ETA, next-task
/// suggestions, analytics. Only the title's "Parent › Child" prefix
/// resolution is reused from #20; nothing else of the full timer's content.
///
/// # Resizable layout adaptation (issue #28)
/// The compact main window is user-resizable (clamped to
/// `MiniTimerWindowLayout`'s min/max bounds), so the
/// view no longer pins a fixed frame: it fills the compact window and
/// adapts. The countdown digits scale with the window height through the
/// pure `MiniTimerWindowLayout.countdownFontSize(forContentSize:)` helper
/// (22pt at the min height → the #15 token base at the default size → 44pt
/// at the max height, measured via a container-size preference so no
/// AppKit/geometry API leaks into this file). Title, countdown and the
/// session-number line are all single-line with a `minimumScaleFactor`, so
/// narrow widths and tight heights degrade by scaling — never by clipping
/// or overlapping (the honest visual confirmation of the pinned minimum is
/// #25's manual pass). Content centers in the larger card at big sizes;
/// the control row stays natural-size and usable across the whole range.
///
/// # Session number (issue #21 criterion 2 — no refetch)
/// Read from `AppModel.sessionNumberToday` — the **#20 snapshot** lifted
/// into the model: `TimerView` fetched it once on appear and recorded it
/// here; the mini view only reads the lifted value. Same graceful-omission
/// semantics as #20: when the snapshot was unavailable (no vault, fetch
/// failure) the value is `nil` and the line is omitted, never guessed.
///
/// # Ticking (#20 pattern, issue #21 criterion 2)
/// A `TimelineView(.periodic)` re-renders about once per second and derives
/// the display state via the pure `TimerDisplayState.derive` through the
/// `AppModel` passthroughs — **no engine mutation**. While paused the
/// engine's paused accumulators freeze the countdown exactly as they freeze
/// the full view's (#12 semantics).
///
/// # End flow (issue #22, PRD §9.5, §12)
/// The End/Stop control opens the same minimal End/Cancel confirm as the
/// full timer (§9.5) and, on confirm, calls the SAME `AppModel` end path
/// (`endSession()` — both controls call the one path). The engine ends, the
/// `FocusSessionResult` is retained, and the phase swaps to
/// `.endingSession` — the observable-driven sync restores normal main-window
/// presentation showing the timer with the blocking
/// end-of-session modal over it (the ONE presentation path, in the app
/// shell). Submission returns the app to Tasks.
/// Opening the confirmation first uses the same model-owned #38 pause as the
/// full timer; Cancel conditionally resumes only a pause that flow created.
///
/// # Expiry watch (issue #33)
/// This view runs the same ~1 s `evaluateSessionExpiry()` watch loop as the
/// full timer (see its type documentation), so mini mode is covered for the
/// expiry alarm/auto-end: while collapsed this compact window is the visible surface,
/// and an expiry while unfocused starts the alarm — which restores the FULL
/// timer (the model's `restoreFromMiniTimer()` on the alarm path) so the
/// pinned shake is actually visible. The mini view itself deliberately
/// never shakes (engineer's choice, documented) — beeps plus the restored
/// shaking full window are the alarm's surface here.
///
/// # Ring color RED (issue #35): n/a by pinned design — documented
/// The mini deliberately shows **no ring** (pinned PRD §11 content: title,
/// countdown, session number, Pause/Resume, End/Stop — re-affirmed through
/// #28's adaptive countdown sizing, which a surrounding ring could not fit
/// without shrinking the countdown). Issue #35's red ring therefore lives
/// on the full timer only (`TimerView`); `DesignTokens.focusRing` is the
/// ONE ring color token, so any future mini-mode ring must reuse it — the
/// two countdowns then match by construction.
struct MiniTimerView: View {
    /// The running session's display context (resolved at start, issue #19;
    /// passed directly from the app shell).
    let context: AppModel.SessionContext
    /// The composition root — the same authoritative passthroughs as every
    /// other view, plus the lifted #20 session-number snapshot.
    let model: AppModel

    @State private var showsEndConfirmation = false
    /// The live compact-window content size (issue #28): captured from layout via a
    /// preference (no AppKit), driving the countdown's adaptive font. Starts
    /// at the default size so the first render is already correct.
    @State private var containerSize = MiniTimerWindowLayout.contentSize

    var body: some View {
        VStack(spacing: DesignTokens.spacingS) {
            displayArea
            controls
        }
        .padding(DesignTokens.spacingM)
        // Fill the resizable compact window (issue #28) instead of pinning the #21
        // fixed frame; content centers in the larger card at big sizes.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(containerSizeProbe)
        .background(miniBackground)
        .confirmationDialog(
            "End this session?",
            isPresented: $showsEndConfirmation,
            titleVisibility: .visible
        ) {
            // The same `AppModel` path the full timer's End control calls
            // (issue #22): on confirm the phase enters `.endingSession` and
            // the sync restores normal main-window presentation with
            // the end-of-session modal over the timer.
            Button("End Session", role: .destructive, action: endSession)
            Button("Cancel", role: .cancel) { model.cancelEndSessionConfirmation() }
        } message: {
            Text(
                "The session ends now. A short wrap-up form opens before the app returns to the tasks."
            )
        }
        .task {
            // The #33 expiry watch (issue #33): the same ~1 s idempotent
            // loop the full `TimerView` runs, so mini mode is covered too —
            // the compact main window is the visible surface while collapsed,
            // and expiry while unfocused
            // starts the alarm (which restores the full timer so the shake
            // is actually visible). Fully guarded — no-ops unless an
            // unhandled expiry is pending on a live session.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.evaluateSessionExpiry()
            }
        }
    }

    /// Invisible layout probe feeding `containerSize` (issue #28): pure
    /// SwiftUI measurement of the frame this view fills, so the countdown
    /// font can adapt through the pure `MiniTimerWindowLayout` helper without
    /// importing AppKit here. The measured size is the compact window content
    /// frame (independent of the font), so no feedback loop.
    private var containerSizeProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MiniTimerContainerSizeKey.self,
                value: proxy.size)
        }
        .onPreferenceChange(MiniTimerContainerSizeKey.self) { size in
            containerSize = size
        }
    }

    // MARK: - Display area (title + countdown + session number)

    /// The click-to-restore display area (issue #21 criterion 3): tapping
    /// it brings the full timer back (the dedicated expand button below is
    /// the always-visible affordance). The control row is deliberately
    /// outside this gesture so Pause/End taps never restore.
    private var displayArea: some View {
        VStack(spacing: DesignTokens.spacingXS) {
            Text(displayTitle)
                .font(DesignTokens.statusGroupFont)
                .lineLimit(1)
                // #28 graceful narrow-width degradation: scale, never clip
                // or overlap (the floor keeps long "Parent › Child" chains
                // legible at the pinned minimum width).
                .minimumScaleFactor(0.5)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let state = displayState()
                Text(state.countdownText)
                    .font(.system(
                        size: MiniTimerWindowLayout.countdownFontSize(
                            forContentSize: containerSize),
                        weight: .thin,
                        design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    // #28: the pure helper picks the size for the window;
                    // the scale factor is the belt-and-braces guarantee that
                    // even an unexpected tight proposal degrades by scaling.
                    .minimumScaleFactor(0.5)
                    .opacity(state.isPaused ? DesignTokens.pausedTextOpacity : 1)
                    .animation(DesignTokens.stateAnimation, value: state.isPaused)
            }
            // The lifted #20 snapshot; omitted entirely when it was
            // unavailable (graceful omission, same semantics as #20).
            if let number = model.sessionNumberToday {
                Text("Session \(number) today")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: restoreFullTimer)
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.spacingS) {
            // Label swaps Pause ↔ Resume (issue #20 criterion 4); paused
            // dims the countdown above.
            Button {
                togglePause()
            } label: {
                Label(
                    displayState().isPaused ? "Resume" : "Pause",
                    systemImage: displayState().isPaused ? "play.fill" : "pause.fill")
            }
            Button(role: .destructive) {
                if model.beginEndSessionConfirmation() {
                    showsEndConfirmation = true
                }
            } label: {
                Label("End", systemImage: "stop.fill")
            }
            // Dedicated restore affordance (issue #21 criterion 3) alongside
            // the click-to-restore display area.
            Button {
                restoreFullTimer()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .help("Restore the full timer")
        }
        .controlSize(.small)
    }

    /// The visible shape of the borderless compact window: a rounded dark card
    /// matching `DesignTokens.background` (the window itself is transparent,
    /// so these corners are the real window corners).
    private var miniBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.panelCornerRadius, style: .continuous)
            .fill(DesignTokens.background)
            .overlay(
                RoundedRectangle(
                    cornerRadius: DesignTokens.panelCornerRadius, style: .continuous)
                    .strokeBorder(DesignTokens.divider, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }

    // MARK: - Derivation + actions (mirrors of the #20 helpers)

    /// One explicit, idempotent command shared by the two disjoint restore
    /// affordances. The display gesture does not cover the controls row, so
    /// one click can enter this function only once.
    private func restoreFullTimer() {
        model.restoreFromMiniTimer()
    }

    /// The task title — "Parent › Child" for a subtask target, the plain
    /// title otherwise (the same resolution as #20's `TimerView`).
    private var displayTitle: String {
        if let parent = context.parentTaskTitle {
            return "\(parent) › \(context.title)"
        }
        return context.title
    }

    /// One tick's display state: the engine's pure functions at the current
    /// monotonic reading, through the `AppModel` passthroughs — read-only,
    /// nothing mutates the engine (the #20 pattern).
    private func displayState() -> TimerDisplayState {
        TimerDisplayState.derive(
            remainingSeconds: model.remainingSeconds,
            progressFraction: model.progressFraction,
            isPaused: model.sessionState == .paused)
    }

    /// Pause/Resume via the same coordinator passthroughs as the full view.
    private func togglePause() {
        if model.sessionState == .paused {
            try? model.resumeSession()
        } else {
            try? model.pauseSession()
        }
    }

    /// The confirm-End handler (issue #22): the SAME `AppModel` path the
    /// full timer's End control calls. Ends the engine, retains the result
    /// and enters `.endingSession` — the sync restores normal main-window
    /// presentation with the end-of-session modal over it.
    /// The engine refuses a second end by contract; that cannot arise from
    /// the confirm, so the typed refusal is dropped here (house style).
    private func endSession() {
        guard model.isSessionActive else { return }
        _ = try? model.endSession()
    }
}

/// Preference key carrying the mini view's container size (issue #28): the
/// plumbing behind `MiniTimerView.containerSizeProbe` — pure SwiftUI, no
/// AppKit, no state beyond the value itself.
private struct MiniTimerContainerSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
