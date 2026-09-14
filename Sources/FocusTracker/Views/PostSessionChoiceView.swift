import SwiftUI

/// The minimal post-session choice (issue #23, PRD §14.1, §20.7): after the
/// end-of-session modal is submitted, the flow stops here for the explicit
/// choice — **Start Next Session** or **Take Break**. NOTHING auto-starts
/// and NO break auto-begins (§14.1; §19 non-goals: automatic break start).
/// Presented by the app shell's ONE phase-driven path for
/// `AppPhase.postSessionChoice` (inline view — the engineer's choice
/// documented on the phase: after the blocking modal the timer has nothing
/// to render under a sheet, so a full calm screen is more honest than a
/// small sheet over nothing).
///
/// # Partial-outcome warning (issue #23 criterion 3)
/// On the `.completionFailedAfterLog` path the phase payload carries the
/// §6.5 completion failure, surfaced here INLINE so the insertion does not
/// swallow #22's documented guidance: the session IS logged, the task was
/// NOT marked Done — complete it manually from the task list.
///
/// # Break duration (issue #23 criterion 5, §14.2)
/// Configurable BEFORE the break starts, right at this choice step
/// (engineer's choice, documented placement): a stepper over whole minutes,
/// defaulting to the pinned 5 minutes, feeding `AppModel.takeBreak(duration:)`.
/// No mid-break reconfiguration exists.
struct PostSessionChoiceView: View {
    /// The composition root — `chooseStartNextSession()` and
    /// `takeBreak(duration:)` are the pinned paths.
    /// Issue #34 amends #23's pinned exit: Start Next Session now opens
    /// the session-start sheet directly (the `.sessionStart` phase)
    /// instead of returning to Tasks.
    let model: AppModel
    /// The §6.5 completion failure carried from the
    /// `.completionFailedAfterLog` submission; nil on the `.success` path.
    let completionFailure: VaultStoreError?

    @State private var breakMinutes = 5
    @State private var breakStartFailure: String?

    var body: some View {
        VStack(spacing: DesignTokens.spacingL) {
            Text("Session logged")
                .font(DesignTokens.titleFont)
            Text("What's next?")
                .font(DesignTokens.statusGroupFont)
                .foregroundStyle(.secondary)
            if let failure = completionFailure {
                partialWarning(failure)
            }
            VStack(spacing: DesignTokens.spacingM) {
                Button("Start Next Session") {
                    model.chooseStartNextSession()
                }
                .buttonStyle(.borderedProminent)
                breakSection
            }
            if let failureText = breakStartFailure {
                Text(failureText)
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(DesignTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.background)
    }

    /// The #22 partial-outcome guidance, inline (criterion 3) — the same
    /// honest message the modal's partial path documented, now kept visible
    /// while the user decides what's next.
    private func partialWarning(_ failure: VaultStoreError) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text(
                "Session logged, but the task was not marked Done — "
                    + "complete it manually from the task list."
            )
            .font(DesignTokens.annotationFont)
            .foregroundStyle(DesignTokens.warning)
            .fixedSize(horizontal: false, vertical: true)
            Text(failure.description)
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: 420, alignment: .leading)
        .background(DesignTokens.bannerBackground)
        .cornerRadius(DesignTokens.cornerRadius)
    }

    private var breakSection: some View {
        VStack(spacing: DesignTokens.spacingS) {
            Stepper("Break: \(breakMinutes) min", value: $breakMinutes, in: 1...60)
                .frame(width: 240)
            Button("Take Break") {
                do {
                    try model.takeBreak(duration: TimeInterval(breakMinutes) * 60)
                } catch {
                    // Unreachable from the choice phase (no break can be
                    // running here); surfaced, never swallowed — the only
                    // thrown case is `.breakAlreadyActive`.
                    breakStartFailure = String(describing: error)
                }
            }
            .buttonStyle(.bordered)
        }
    }
}
