import Foundation

/// Pure display helpers for the full-screen timer view (issue #20, PRD
/// §10.1, §21) — formatting and clamping only: no SwiftUI, no I/O, no time
/// source of its own. Every caller supplies values read from the engine's
/// pure functions through the `AppModel` passthroughs (`remainingSeconds`,
/// `progressFraction`) and the clock seam (`sessionClock.wallClockNow`) —
/// nothing here calls `Date()` or mutates the engine. Kept out of the view
/// file so every formatting rule is unit-testable without SwiftUI (issue #20,
/// criterion 8).
enum TimerDisplay {

    /// Formats remaining whole seconds as the big countdown (PRD §10.1):
    /// `m:ss` below one hour ("25:00", "4:05"), `h:mm:ss` at or above one
    /// hour ("1:00:00"), and "0:00" at expiry. Negative input is clamped to
    /// zero — a countdown never overstates (the engine's `remainingSeconds`
    /// already clamps at 0; this is the display-side guarantee).
    static func countdownText(remainingSeconds: Int) -> String {
        let clamped = max(0, remainingSeconds)
        if clamped >= 3600 {
            return String(
                format: "%d:%02d:%02d",
                clamped / 3600, (clamped % 3600) / 60, clamped % 60)
        }
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// Formats the estimated finish time (PRD §10.1): wall-clock `now` plus
    /// `remainingSeconds`, rendered `HH:mm` in the user's local time. Pure —
    /// the caller reads the wall clock from the session clock seam
    /// (`sessionClock.wallClockNow`), never `Date()` here.
    ///
    /// The fixed `en_US_POSIX` locale pins the output to the literal `HH:mm`
    /// symbols (24-hour) regardless of the user's locale/12-hour preference —
    /// the format string, not the locale, decides the shape.
    ///
    /// While paused the remaining seconds are frozen (#12 semantics), so this
    /// recomputes each tick as "finish if resumed right now" — an honest
    /// live estimate that keeps its distance from the countdown (documented,
    /// issue #20).
    static func etaText(remainingSeconds: Int, now: Date) -> String {
        let finish = now.addingTimeInterval(TimeInterval(max(0, remainingSeconds)))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: finish)
    }

    /// The current session number for a task today (PRD §10.1 "Session N
    /// today", issue #20): one more than the number of sessions already
    /// logged for the task on that day — an empty list (no log file yet)
    /// means this is session 1. Consumes exactly the #11 helper result
    /// `DailyLogStore.sessions(for:on:)` whose count this was written for.
    static func sessionNumber(fromSessions sessions: [FocusSessionLog]) -> Int {
        sessions.count + 1
    }

    /// The ring trim fraction (PRD §10.1): the engine's `progressFraction`
    /// clamped to 0…1 (1 == expired). The view draws the remaining arc from
    /// this offset to 1, so the ring visibly shrinks as time passes. The
    /// engine already clamps; this is the display-side guarantee.
    static func ringTrim(progressFraction: Double) -> Double {
        min(1, max(0, progressFraction))
    }
}

/// The complete display state the timer view renders for one tick (issue #20,
/// criterion 8): a pure derivation over the engine's pure functions —
/// `remainingSeconds` / `progressFraction` at the current monotonic reading —
/// plus the observable pause flag. Nothing here mutates the engine: the
/// `TimelineView(.periodic)` re-render supplies fresh engine readings every
/// second (the time-derived `AppModel` properties are documented non-reactive;
/// the view drives re-rendering, issue #20 criterion 3).
struct TimerDisplayState: Equatable {
    /// Whole seconds still left, clamped at 0. The engine returns nil only
    /// for an *idle* session — treated here as 0 for display totality; the
    /// timer view only renders while a session is active.
    let remainingSeconds: Int
    /// The formatted countdown (see `TimerDisplay.countdownText`).
    let countdownText: String
    /// Clamped progress → ring trim (see `TimerDisplay.ringTrim`).
    let ringTrim: Double
    /// True once remaining hits 0 — the pinned #12 expiry semantics: the
    /// engine clamps `remainingSeconds` at 0 exactly when focused time
    /// reaches the configured duration, so for an active session
    /// `remainingSeconds == 0` is equivalent to `isExpired(at:)` (documented,
    /// issue #20 criterion 7: no auto-end, the session stays active).
    let isExpired: Bool
    /// Whether the session is paused — display freezes (the open pause
    /// segment contributes nothing to focused time, #12 engine semantics).
    let isPaused: Bool

    /// Pure derivation from the engine's pure-function readings plus the
    /// observable session state. No I/O, no clock, no mutation — fully
    /// unit-testable (issue #20 criterion 8).
    static func derive(
        remainingSeconds: Int?,
        progressFraction: Double,
        isPaused: Bool
    ) -> TimerDisplayState {
        let remaining = max(0, remainingSeconds ?? 0)
        return TimerDisplayState(
            remainingSeconds: remaining,
            countdownText: TimerDisplay.countdownText(remainingSeconds: remaining),
            ringTrim: TimerDisplay.ringTrim(progressFraction: progressFraction),
            isExpired: remaining == 0,
            isPaused: isPaused)
    }
}
