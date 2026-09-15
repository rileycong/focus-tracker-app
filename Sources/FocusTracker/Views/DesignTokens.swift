import SwiftUI

/// The visual language of the app (issue #15, PRD §21: "dark, minimal, calm,
/// no dashboard feel"). One place for spacing, sizing, typography and the
/// dark-first palette so the views stay consistent and the PRD's direction is
/// enforced by construction. The app root additionally forces
/// `.preferredColorScheme(.dark)`, so the fixed (non-adaptive) colors below
/// always render against dark.
enum DesignTokens {

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 14
    static let spacingL: CGFloat = 20

    // MARK: - Sizing

    /// Diameter of the subtle status dot in a task row.
    static let statusDotSize: CGFloat = 8
    /// Vertical padding inside a task row.
    static let rowVerticalPadding: CGFloat = 7
    /// Corner radius for chips and the selection highlight.
    static let cornerRadius: CGFloat = 6
    /// Corner radius of the mini panel's floating card — a window shape, one
    /// calm step above the chip radius.
    static let panelCornerRadius: CGFloat = 12
    /// Countdown ring stroke width — shared by the full timer and the break
    /// screen so the two countdowns read as one visual language.
    static let ringLineWidth: CGFloat = 10
    /// Point size of the mini panel's countdown digits (fixed — the panel has
    /// a fixed content size, unlike the full timer's diameter-derived size).
    static let miniCountdownSize: CGFloat = 30
    /// Onboarding hero icon point size.
    static let emptyStateIconSize: CGFloat = 40
    /// Minimum height of the notes editor in both forms (one editor shape).
    static let notesEditorMinHeight: CGFloat = 80
    /// Disclosure chevron glyph size in task/subtask rows.
    static let chevronIconSize: CGFloat = 9
    /// Chip remove glyph size in the forms' category tokens.
    static let chipRemoveIconSize: CGFloat = 9

    // Tasks inventory sizing is intentionally separate so forms, sheets and
    // timer surfaces keep their existing scale.
    static let tasksParentTitleSize: CGFloat = 16
    static let tasksSubtaskTitleSize: CGFloat = 14
    static let tasksMetadataSize: CGFloat = 12
    static let tasksChipSize: CGFloat = 11
    static let tasksStatusDotSize: CGFloat = 9
    static let tasksChevronIconSize: CGFloat = 10
    static let tasksRowVerticalPadding: CGFloat = 10
    static let tasksRowSpacing: CGFloat = 4
    static let tasksSubtaskIndent: CGFloat = 22

    // MARK: - Motion (subtle per PRD §21 — timing, no effects)

    /// The ring's per-second tick — linear so the arc advances evenly.
    static let ringTickAnimation: Animation = .linear(duration: 1)
    /// Subtle state changes (pause dim in/out, expiry banner fade).
    static let stateAnimation: Animation = .easeInOut(duration: 0.35)
    /// Arc opacity while paused — dimmed but visible.
    static let pausedArcOpacity: CGFloat = 0.45
    /// Countdown text opacity while paused — slightly brighter than the arc
    /// so the frozen number stays readable.
    static let pausedTextOpacity: CGFloat = 0.55

    // MARK: - Typography

    /// Project section headers.
    static let sectionFont: Font = .headline
    /// Status sub-group headers.
    static let statusGroupFont: Font = .subheadline.weight(.semibold)
    /// Priority/effort chips and category labels.
    static let chipFont: Font = .system(size: 10, weight: .medium)
    /// Deadline and count annotations.
    static let annotationFont: Font = .caption
    /// Row and field body text (task titles, form text fields, editors).
    static let bodyFont: Font = .body
    /// Large screen/sheet titles (the timer's task title, the break screen,
    /// the post-session choice, the end-of-session modal, onboarding) — the
    /// single large step in the type scale.
    static let titleFont: Font = .title2
    /// Sheet headers (task/subtask forms) and the degraded-state banner
    /// title — the mid-weight heading between `titleFont` and the row fonts.
    static let sheetHeaderFont: Font = .headline
    /// Tasks inventory hierarchy: parents lead; nested rows and metadata step down.
    static let tasksParentTitleFont: Font = .system(
        size: tasksParentTitleSize, weight: .semibold)
    static let tasksSubtaskTitleFont: Font = .system(size: tasksSubtaskTitleSize)
    static let tasksMetadataFont: Font = .system(size: tasksMetadataSize)
    static let tasksChipFont: Font = .system(size: tasksChipSize, weight: .medium)

    // MARK: - Colors (dark-first; the app enforces `.dark` at the root)

    /// Window background.
    static let background = Color(white: 0.12)
    /// Hairline separators between sections.
    static let divider = Color.white.opacity(0.08)
    /// Chip / label capsule background.
    static let chipBackground = Color.white.opacity(0.08)
    /// Selection highlight for a task row (soft accent wash, not a dashboard
    /// card).
    static let selectionBackground = Color(red: 0.30, green: 0.52, blue: 0.95)
        .opacity(0.22)
    /// Overdue deadline text — visually distinct from future deadlines.
    static let overdue = Color(red: 1.0, green: 0.44, blue: 0.40)
    /// Degraded-state banner background.
    static let bannerBackground = Color(red: 0.28, green: 0.19, blue: 0.08)
    /// Degraded-state banner icon color.
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.32)
    /// The focus session's countdown ring (issue #35): a calm dark-theme
    /// red — the user's requested focus-ring color, tuned for the enforced
    /// dark theme (PRD §21): enough lightness that the 10pt ring reads
    /// clearly on the `background` dark gray (~5.4:1; the previous blue
    /// was ~5.9:1), muted enough to stay calm rather than alarm-red.
    /// Deliberately its own token — NOT `overdue`/`priorityColor(.high)`
    /// (those carry deadline/priority semantics; the ring carries "focus
    /// session running"). Paused dimming checked against this tone: the
    /// `pausedArcOpacity`-dimmed arc keeps ~2.3:1, parity with the blue it
    /// replaces (~2.4:1) — dimmed but visible, as before.
    static let focusRing = Color(red: 1.0, green: 0.45, blue: 0.42)
    /// The expired/completed focus ring (issue #35): the full circle the
    /// ring completes into at expiry — a lighter, settled tint of the SAME
    /// red family, so the "done" highlight stays in the user's requested
    /// red hue and stays the most legible state on the dark background.
    /// The BREAK ring deliberately keeps the green `statusColor(.done)`
    /// completion (issue #35 changes only the focus rings; the break ring
    /// stays blue — see `BreakView`).
    static let focusRingCompleted = Color(red: 1.0, green: 0.60, blue: 0.56)

    /// The subtle per-status indicator color (PRD §21: unobtrusive metadata —
    /// a small dot, never a loud badge).
    static func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .toDo: Color(white: 0.62)
        case .inProgress: Color(red: 0.42, green: 0.66, blue: 1.0)
        case .blocked: Color(red: 1.0, green: 0.60, blue: 0.33)
        case .done: Color(red: 0.45, green: 0.81, blue: 0.56)
        case .dropped: Color(white: 0.34)
        }
    }

    /// Priority chip tint — only `high` gets a color; the rest stay neutral
    /// to keep rows calm.
    static func priorityColor(_ priority: Priority) -> Color {
        switch priority {
        case .high: Color(red: 1.0, green: 0.44, blue: 0.40)
        case .medium, .low: Color.secondary
        }
    }
}
