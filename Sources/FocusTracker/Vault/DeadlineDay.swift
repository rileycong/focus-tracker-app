import Foundation

/// Fixed `Date` ↔ calendar-day mapping for `deadline` fields (issue #4).
///
/// `deadline` persists as a date-only string, exactly `yyyy-MM-dd` in `en_US_POSIX`.
/// Internally the calendar day is represented as a `Date` at **noon UTC** on that day:
/// formatting uses the UTC time zone, so a date can never shift by a day no matter
/// what the process's local time zone is (noon ± 12h still lands on the same UTC day,
/// and the formatter never consults local time).
///
/// Parsing is strict: the string must re-format to itself, so `2026-1-5` or
/// `2026-02-30` are rejected instead of being silently normalized.
enum DeadlineDay {
    /// Parses `yyyy-MM-dd` (en_US_POSIX, UTC) into the UTC-noon `Date` for that day,
    /// or nil when the string is not exactly a valid calendar date.
    static func date(from string: String) -> Date? {
        let formatter = makeFormatter()
        guard let parsed = formatter.date(from: string) else { return nil }
        guard formatter.string(from: parsed) == string else { return nil }
        // DateFormatter yields midnight UTC for the day; normalize to UTC noon.
        return parsed.addingTimeInterval(12 * 60 * 60)
    }

    /// Formats a `Date` as its UTC calendar day, `yyyy-MM-dd`.
    /// Stable for any time of day because the output time zone is fixed to UTC.
    static func string(from date: Date) -> String {
        makeFormatter().string(from: date)
    }

    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
