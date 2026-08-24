import Foundation

/// One bar of the dashboard's "Spesa giornaliera" chart, as produced by
/// `dailyBars(_:)`.
///
/// `fraction` is this bar's height relative to the tallest bar in the series,
/// in `0...1` — the view converts it to a concrete height at draw time,
/// keeping this type free of any drawing framework, same split as
/// `DonutSegment`.
public struct DailyBar: Sendable, Equatable {
    /// The UTC calendar day this bar represents.
    public let day: CalendarDate
    /// Total spending on this day, minor units, a non-negative magnitude.
    public let spending: Int
    /// This bar's height relative to the series' tallest bar. `0` for every
    /// bar when the whole series is `0` (nothing to compare against).
    public let fraction: Double

    public init(day: CalendarDate, spending: Int, fraction: Double) {
        self.day = day
        self.spending = spending
        self.fraction = fraction
    }
}

/// A `Calendar` pinned to UTC, matching the UTC-day bucketing
/// `domain/dashboard.py::_day_of` performs on the backend — the same
/// construction `CalendarDateFormatter.formatCalendarDate` uses to round-trip
/// a `CalendarDate` through `Date` for a purpose (here, "the next day") that
/// `CalendarDate` itself does not carry. Built locally rather than cached in
/// a shared static, same `Sendable` reason as `JSONCoding`'s formatters.
private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
}

/// The calendar day immediately after `date`, in UTC.
private func nextDay(after date: CalendarDate, calendar: Calendar) -> CalendarDate? {
    var components = DateComponents()
    components.year = date.year
    components.month = date.month
    components.day = date.day
    components.timeZone = TimeZone(identifier: "UTC")
    guard let resolved = calendar.date(from: components),
        let advanced = calendar.date(byAdding: .day, value: 1, to: resolved)
    else { return nil }
    return CalendarDate(date: advanced, calendar: calendar)
}

extension TraccioCore {
    /// Turn a currency's `by_day` breakdown into a drawable, gap-free bar series.
    ///
    /// `entries` need not cover every day in the period — a day with no
    /// transactions is simply absent from `by_day` (backend-side, an empty
    /// dict entry is never emitted). This function fills every day between
    /// the earliest and latest entry present with a zero bar, so the chart
    /// never renders unevenly spaced bars; it does **not** extend the axis to
    /// the full requested period, since the caller's period (`MonthPeriod`)
    /// is in local time while these buckets are UTC days, and reconciling the
    /// two would risk a day silently falling outside the axis (see
    /// `docs/decisions/0007-dashboard-aggregation.md`'s 2026-08-25 revision).
    ///
    /// Parameters
    /// ----------
    /// entries:
    ///     One currency's `byDay` list, in any order.
    ///
    /// Returns
    /// -------
    /// One `DailyBar` per UTC day from the earliest to the latest entry,
    /// inclusive, sorted chronologically. Empty if `entries` is empty.
    public static func dailyBars(_ entries: [DaySummaryResponse]) -> [DailyBar] {
        guard !entries.isEmpty else { return [] }

        let spendingByDay = Dictionary(
            entries.map { ($0.date, $0.spending) },
            uniquingKeysWith: { first, _ in first }
        )
        let days = spendingByDay.keys.sorted()
        guard let first = days.first, let last = days.last else { return [] }

        let calendar = utcCalendar()
        var series: [CalendarDate] = []
        var cursor = first
        while cursor <= last {
            series.append(cursor)
            guard let next = nextDay(after: cursor, calendar: calendar) else { break }
            cursor = next
        }

        let maxSpending = spendingByDay.values.max() ?? 0
        return series.map { day in
            let spending = spendingByDay[day] ?? 0
            let fraction = maxSpending > 0 ? Double(spending) / Double(maxSpending) : 0
            return DailyBar(day: day, spending: spending, fraction: fraction)
        }
    }
}
