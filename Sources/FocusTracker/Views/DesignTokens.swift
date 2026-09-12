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

    // MARK: - Typography

    /// Project section headers.
    static let sectionFont: Font = .headline
    /// Status sub-group headers.
    static let statusGroupFont: Font = .subheadline.weight(.semibold)
    /// Priority/effort chips and category labels.
    static let chipFont: Font = .system(size: 10, weight: .medium)
    /// Deadline and count annotations.
    static let annotationFont: Font = .caption

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
