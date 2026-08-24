import Foundation

extension TraccioCore {
    /// Format a `CalendarDate` for display, localized.
    ///
    /// Builds a `DateComponents`-based `Date` purely for `DateFormatter`'s
    /// benefit — `CalendarDate` itself stays a plain year/month/day value with
    /// no time zone, so this construction happens only here, at the display
    /// boundary, and is discarded immediately after formatting.
    ///
    /// Parameters
    /// ----------
    /// date:
    ///     The calendar date to format.
    /// locale:
    ///     Locale for the formatted string. Defaults to `.current`.
    ///
    /// Returns
    /// -------
    /// A short, localized date string, e.g. `"1 ago 2026"`.
    public static func formatCalendarDate(_ date: CalendarDate, locale: Locale = .current) -> String {
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        components.timeZone = TimeZone(identifier: "UTC")

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current

        guard let resolved = calendar.date(from: components) else { return date.wireValue }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: resolved)
    }
}
