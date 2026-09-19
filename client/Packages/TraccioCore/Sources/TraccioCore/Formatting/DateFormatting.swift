import Foundation

extension TraccioCore {
    /// A named date/time display shape, replacing the app's ad-hoc
    /// `DateFormatter` templates.
    ///
    /// Before this type existed, nine call sites across `App/` each built
    /// their own `DateFormatter` with their own inline pattern — two pairs of
    /// which were the exact same pattern under different names
    /// (`TransferSuggestionCard`/`TransactionsView` both used `"d MMMM"`),
    /// and one pair which should have been the same concept but silently
    /// diverged (`AdvancesView` rendered an advance's date without a year,
    /// `PersonDetailView` rendered the same field with one). One enum plus
    /// `formatDate(_:style:)` names every shape once.
    public enum DateDisplayStyle {
        /// `"17 settembre"` — day and full month, no year.
        case dayMonth
        /// `"17 settembre 2026"` — day, full month, and year.
        case dayMonthYear
        /// `"17 set 2026"` — day, abbreviated month, and year.
        case dayMonthAbbreviatedYear
        /// `"17 settembre 2026, 14:30"` — a full date plus a 24h time.
        case dayMonthYearTime
        /// `"mar 2026"` — abbreviated month and year, no day.
        case monthYearAbbreviated
        /// `"agosto 2026"` — full month and year, no day.
        case monthYear
        /// `"2026"` — year only.
        case year

        fileprivate var template: String {
            switch self {
            case .dayMonth: "d MMMM"
            case .dayMonthYear: "d MMMM yyyy"
            case .dayMonthAbbreviatedYear: "d MMM yyyy"
            case .dayMonthYearTime: "d MMMM yyyy, HH:mm"
            case .monthYearAbbreviated: "MMM yyyy"
            case .monthYear: "MMMM yyyy"
            case .year: "yyyy"
            }
        }
    }

    /// Format a `Date` for display in one of the app's named shapes.
    ///
    /// Builds a fresh `DateFormatter` per call rather than sharing a mutable
    /// static — the same `Sendable`-safe posture `docs/engineering.md`
    /// asks for (see the removed `TransferSuggestionCard.dateFormatter` and
    /// `TransferSection.dateFormatter` this replaces). Uses the device's own
    /// time zone (unset, `DateFormatter`'s default) since callers pass real
    /// instants — a transaction's booked time, an advance's date — that
    /// should read in local wall-clock time, unlike `CalendarDate`'s
    /// pure-day values in `formatCalendarDate`, which are pinned to UTC.
    ///
    /// Parameters
    /// ----------
    /// date:
    ///     The instant to format.
    /// style:
    ///     Which named shape to render it in.
    /// locale:
    ///     Locale for the formatted string. Defaults to `italianLocale`,
    ///     same as `formatCalendarDate` — the UI has no localization tables,
    ///     so a date must read in Italian regardless of the device's own
    ///     locale.
    ///
    /// Returns
    /// -------
    /// The formatted string, e.g. `"17 settembre 2026"` for `.dayMonthYear`.
    public static func formatDate(
        _ date: Date, style: DateDisplayStyle, locale: Locale = italianLocale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(style.template)
        return formatter.string(from: date)
    }
}
