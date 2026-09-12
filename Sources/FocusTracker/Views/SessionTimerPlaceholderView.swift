import SwiftUI

/// The minimal placeholder timer screen (issue #19, PRD §9.2, §20.3
/// hand-off): the session's task title and the remaining seconds, plus an
/// End action that ends the session and returns the app to `.tasksView`.
/// Deliberately minimal — #20 replaces this screen with the real
/// full-screen timer (pause/resume, mini mode is #21), and #22 owns the
/// real end-of-session flow (the modal, complete-before-expiry, and the
/// `Logs/` append); the End here discards the `FocusSessionResult` rather
/// than inventing a log path #22 must then undo.
struct SessionTimerPlaceholderView: View {
    /// The running session's display context (resolved at start, issue #19).
    let context: AppModel.SessionContext
    /// The composition root — the same authoritative passthroughs
    /// (`remainingSeconds`, `isSessionActive`, `endSession`) every layer uses.
    let model: AppModel

    var body: some View {
        VStack(spacing: DesignTokens.spacingL) {
            Text(displayTitle)
                .font(.title2)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.spacingL)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(timeText)
                    .font(.system(size: 64, weight: .thin, design: .monospaced))
                    .monospacedDigit()
            }
            if !context.categories.isEmpty {
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
            Button("End Session") { end() }
                .buttonStyle(.bordered)
                .disabled(!model.isSessionActive)
                .help("End the session and return to the tasks (the full end flow comes with #22)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.background)
    }

    /// "Parent › Child" for a subtask target, the plain title otherwise.
    private var displayTitle: String {
        if let parent = context.parentTaskTitle {
            return "\(parent) › \(context.title)"
        }
        return context.title
    }

    /// Remaining whole seconds as m:ss (floored/clamped by the engine's
    /// `remainingSeconds` — a countdown never overstates). Re-evaluated on
    /// every one-second tick of the `TimelineView`.
    private var timeText: String {
        let seconds = model.remainingSeconds ?? 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The minimal end path: the model's `endSession` (coordinator end +
    /// snapshot clear) swaps `appPhase` back to `.tasksView`. The result is
    /// discarded — #22 owns the real end flow (documented above).
    private func end() {
        guard model.isSessionActive else { return }
        _ = try? model.endSession()
    }
}
