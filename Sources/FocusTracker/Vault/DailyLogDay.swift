import Foundation

/// The daily-log date conventions (issue #11), defined here in ONE place and
/// used consistently by read, append and the `sessions(for:on:)` helper.
///
/// # Filename convention
/// The day file for an instant is `Logs/YYYY-MM-DD.md`, where `YYYY-MM-DD` is
/// the instant's calendar day in the process's **local** time zone
/// (`Calendar.current`): the PRD's day files are per *local* calendar day
/// (§5.5), so a session that starts before local midnight belongs to the file
/// of its local start day. `appendSession`/`appendBreak`/read/helper all
/// resolve their target file through `fileName(for:)` — the date parameter of
/// every `DailyLogStore` API is any instant on that local calendar day.
///
/// # Timestamp convention
/// Timestamps persist as ISO 8601, second precision, no offset — exactly
/// `2026-09-04T10:00:00` as in the fixture — rendered and parsed in the same
/// local time zone as the filename convention (wall-clock semantics: the
/// string a user reads is their local wall clock).
///
/// The `Date` ↔ string mapping is deterministic by construction:
/// - `en_US_POSIX`, non-lenient formatter, fixed format
///   `yyyy-MM-dd'T'HH:mm:ss`, the local time zone.
/// - Parsing is strict (same stance as `DeadlineDay`): the parsed `Date` must
///   re-format to the input string, so `2026-1-5`, `2026-02-30` and times that
///   fall into a DST spring-forward gap (nonexistent local times) are rejected
///   with a typed error instead of being silently shifted.
/// - Known, documented corner: during the DST fall-back hour two distinct
///   instants share one wall-clock string. Writing collapses them (the file
///   format cannot distinguish them); reading resolves the string to the
///   earlier of the two instants. Round-tripping a parsed file
///   (parse → serialize) is still byte-identical, which is what the issue
///   pins.
enum DailyLogDay {
    /// The `YYYY-MM-DD` local calendar day of `date` (`en_US_POSIX`, fixed
    /// format — no locale drift).
    static func dayString(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The day file's name for `date`: `YYYY-MM-DD.md` (local calendar day).
    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        dayString(for: date, calendar: calendar) + ".md"
    }

    /// Formats `date` as the offset-less second-precision timestamp convention
    /// (`2026-09-04T10:00:00`, local wall clock).
    static func timestampString(from date: Date) -> String {
        let formatter = makeTimestampFormatter()
        return formatter.string(from: date)
    }

    /// Strictly parses an offset-less second-precision timestamp into a `Date`
    /// (local wall clock), or nil when the string is not exactly that —
    /// including valid-looking dates whose local time does not exist (DST gap)
    /// or does not re-format to itself.
    static func date(fromTimestamp string: String) -> Date? {
        let formatter = makeTimestampFormatter()
        guard let parsed = formatter.date(from: string) else { return nil }
        guard formatter.string(from: parsed) == string else { return nil }
        return parsed
    }

    private static func makeTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }
}
