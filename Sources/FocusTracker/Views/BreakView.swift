import SwiftUI

/// The break countdown screen (issue #23, PRD §14.2–§14.4, §21): shown
/// exactly while `AppPhase.breakActive` is up — swapped in by the app
/// shell's ONE phase-driven path. Dark, minimal, calm, the session timer's
/// single-priority layout without any of the session context.
///
/// **Presentation (engineer's choice, documented):** the circular ring with
/// the big monospaced countdown inside it — the same calm shape the session
/// timer uses (PRD §21), so the two countdowns read as one visual language.
///
/// **Deliberately NOT shown (pinned do-not-show list, §14.4):** task
/// title/project/categories, "Session N today", ratings, notes, overrun
/// time (the timer stops at expiry; time past expiry is never counted,
/// displayed or logged). A break links to no task and collects no ratings —
/// ratings are collected only after work sessions.
///
/// # Ticking (issue #23 criterion 13, the #20/#21 pattern)
/// A `TimelineView(.periodic)` re-renders about once per second and derives
/// every displayed value from the engine's pure functions through the
/// `AppModel` passthroughs (`breakRemainingSeconds`, `breakProgressFraction`,
/// `isBreakExpired`) — nothing mutates the engine.
///
/// # Expiry (pinned semantics, §14.3)
/// When the countdown hits 0 the ring completes (full "done" color) and an
/// IN-APP notification banner appears — keyed off the model's observable
/// `isBreakExpired` state, re-read on every tick. NOT a system notification
/// (no `UNUserNotificationCenter`). Engineer's choice (documented): a
/// persistent banner under the ring with no sound and NO auto-dismiss — the
/// break screen stays up until the user acts (no auto-start of a focus
/// session, §14.3; §19 non-goals), so a banner that vanished on its own
/// could be missed entirely.
///
/// # Controls (issue #23 criteria 14/16)
/// While the break runs: **End break early** — ends the break now and logs
/// the actual timed duration (§14.4). After expiry the same control becomes
/// **Back to tasks** — the clear path back to `.tasksView`, where the next
/// session is started normally (#19); the break ends and logs at that
/// acknowledgment. One model API (`AppModel.endBreak()`), two labels — the
/// control shape is the engineer's choice, the behavior is pinned.
struct BreakView: View {
    /// The composition root — the break passthroughs and the pinned
    /// `endBreak()` path.
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            // Same pinned sizing shape as TimerView: diameter ≈ min(w, h) * 0.6.
            let diameter = min(geometry.size.width, geometry.size.height) * 0.6
            VStack(spacing: DesignTokens.spacingL) {
                Text("Break")
                    .font(DesignTokens.titleFont)
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    // Ring + banner + control all re-derive on every ~1 s
                    // tick: the control's label swaps at expiry and the
                    // banner appears exactly when the observable
                    // `isBreakExpired` flips true.
                    VStack(spacing: DesignTokens.spacingL) {
                        ringBlock(diameter: diameter)
                        if model.isBreakExpired {
                            expiryBanner
                                .transition(.opacity.animation(DesignTokens.stateAnimation))
                        }
                        endControl
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.background)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func ringBlock(diameter: CGFloat) -> some View {
        let remaining = model.breakRemainingSeconds ?? 0
        let progress = model.breakProgressFraction
        let expired = model.isBreakExpired
        let arc = TimerDisplay.ringArc(progressFraction: progress)
        ZStack {
            // Track.
            Circle()
                .stroke(DesignTokens.divider, lineWidth: DesignTokens.ringLineWidth)
            // Remaining arc: from the clamped progress offset to 1 — the
            // ring shrinks as time passes. At expiry the geometry swaps to
            // the FULL circle (0→1) via the pure, regression-tested
            // `TimerDisplay.ringArc`, completing into the subtle "done"
            // color.
            Circle()
                .trim(from: arc.from, to: arc.to)
                .stroke(
                    expired
                        ? DesignTokens.statusColor(.done)
                        : DesignTokens.statusColor(.inProgress),
                    style: StrokeStyle(
                        lineWidth: DesignTokens.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DesignTokens.ringTickAnimation, value: arc)
            Text(TimerDisplay.countdownText(remainingSeconds: remaining))
                .font(.system(
                    size: diameter * 0.18, weight: .thin, design: .monospaced))
                .monospacedDigit()
        }
        .frame(width: diameter, height: diameter)
    }

    /// The in-app break-finished notification (criterion 15): a persistent
    /// banner — no sound, no auto-dismiss, no auto-start (documented in the
    /// type documentation).
    private var expiryBanner: some View {
        Text("Break finished — head back when you're ready.")
            .font(DesignTokens.statusGroupFont)
            .foregroundStyle(DesignTokens.statusColor(.done))
            .padding(.horizontal, DesignTokens.spacingM)
            .padding(.vertical, DesignTokens.spacingS)
            .background(DesignTokens.chipBackground)
            .cornerRadius(DesignTokens.cornerRadius)
    }

    /// One control, two labels (criteria 14/16): "End break early" while the
    /// break runs — ends now and logs the ACTUAL timed duration; "Back to
    /// tasks" after expiry — the clear path back, ending and logging at that
    /// acknowledgment (the post-expiry duration is the configured one, the
    /// engine clamps).
    private var endControl: some View {
        Button {
            Task { await model.endBreak() }
        } label: {
            Text(model.isBreakExpired ? "Back to tasks" : "End break early")
        }
        .buttonStyle(.bordered)
    }
}
