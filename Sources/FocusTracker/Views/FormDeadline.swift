import Foundation

/// The deadline field's date normalization, shared by the #16 task form and
/// the #17 subtask form: the picked local calendar day in the #4 canonical
/// deadline shape (noon UTC on that day), so the persisted `yyyy-MM-dd` is
/// exactly the day the user picked for any |UTC offset| ≤ 12 h — the same
/// WYSIWYG convention `DeadlineDay` uses for parsing. Extracted verbatim
/// from `TaskFormView` so both forms cannot drift.
enum FormDeadline {
    /// The canonical deadline date for the local calendar day `picked` falls
    /// on (noon UTC on that day).
    static func canonical(from picked: Date) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let day = local.dateComponents([.year, .month, .day], from: picked)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return (utc.date(from: day) ?? picked).addingTimeInterval(12 * 60 * 60)
    }
}
