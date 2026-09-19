import Foundation

extension TraccioCore {
    /// The app's one fixed locale for date/number display.
    ///
    /// Traccio has no localization tables — every string in the UI is
    /// hardcoded Italian (`docs/engineering.md`) — so a date or a number that
    /// followed the *device's* locale instead would read in a different
    /// language than every label around it whenever the device isn't set to
    /// Italian. `MoneyFormatter` already documents the app as
    /// "Italian-first"; this makes the same assumption explicit for dates.
    public static let italianLocale = Locale(identifier: "it_IT")

    /// Turn a `CalendarDate` into a concrete `Date` at UTC midnight, purely
    /// so `DateFormatter` has something to format — `CalendarDate` itself
    /// stays a plain year/month/day value with no time zone. Returns `nil`
    /// only if the components do not form a valid date (never true for a
    /// backend-supplied value).
    private static func resolve(_ date: CalendarDate) -> Date? {
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        components.timeZone = TimeZone(identifier: "UTC")

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)
    }

    /// Format `date` with an explicit pattern, in `locale`'s own calendar —
    /// the shared plumbing behind `formatCalendarDate` and
    /// `formatCalendarDateRange`'s partial (day-only / day-and-month)
    /// pieces.
    ///
    /// Deliberately does **not** pin `formatter.calendar` to `.iso8601`
    /// (unlike the `Calendar` used by `resolve(_:)` above, which only turns
    /// the components into an instant): forcing the formatter itself onto
    /// the ISO-8601 calendar made it fall back to that calendar's own
    /// English month symbols regardless of `locale`, which is the bug this
    /// function fixes — `DateFormatter` picks the right calendar from
    /// `locale` on its own.
    private static func format(_ date: CalendarDate, pattern: String, locale: Locale) -> String {
        guard let resolved = resolve(date) else { return date.wireValue }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: resolved)
    }

    /// Format a `CalendarDate` for display, localized.
    ///
    /// Parameters
    /// ----------
    /// date:
    ///     The calendar date to format.
    /// locale:
    ///     Locale for the formatted string. Defaults to `italianLocale`.
    ///
    /// Returns
    /// -------
    /// A short, localized date string, e.g. `"1 ago 2026"`.
    public static func formatCalendarDate(_ date: CalendarDate, locale: Locale = italianLocale) -> String
    {
        guard let resolved = resolve(date) else { return date.wireValue }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: resolved)
    }

    /// Format a date range for display, collapsing whatever `start` and
    /// `end` already share instead of spelling out both dates in full —
    /// `EventRow`'s subtitle is what this exists for (a full
    /// `"10 set 2026 – 12 set 2026"` was the main cause of that row
    /// wrapping onto a third line).
    ///
    /// Parameters
    /// ----------
    /// start:
    ///     The range's first day.
    /// end:
    ///     The range's last day, or `nil`/equal to `start` for a single-day
    ///     range.
    /// locale:
    ///     Locale for the formatted string. Defaults to `italianLocale`.
    ///
    /// Returns
    /// -------
    /// - A single date, e.g. `"10 set 2026"`, when `end` is `nil` or equal
    ///   to `start`.
    /// - `"10 – 12 set 2026"` when `start` and `end` share a month and year.
    /// - `"28 set – 3 ott 2026"` when they share only a year.
    /// - `"28 dic 2025 – 3 gen 2026"` otherwise.
    public static func formatCalendarDateRange(
        from start: CalendarDate, to end: CalendarDate?, locale: Locale = italianLocale
    ) -> String {
        guard let end, end != start else {
            return formatCalendarDate(start, locale: locale)
        }
        if start.year == end.year, start.month == end.month {
            let day = format(start, pattern: "d", locale: locale)
            return "\(day) – \(formatCalendarDate(end, locale: locale))"
        }
        if start.year == end.year {
            let dayMonth = format(start, pattern: "d MMM", locale: locale)
            return "\(dayMonth) – \(formatCalendarDate(end, locale: locale))"
        }
        return "\(formatCalendarDate(start, locale: locale)) – \(formatCalendarDate(end, locale: locale))"
    }
}
