import Foundation

/// A calendar month, represented as a half-open interval `[start, end)`.
///
/// Backs the dashboard's period selector. `GET /dashboard/summary` takes an
/// optional `start`/`end` pair where `end` is **exclusive**
/// (`docs/decisions/0007-dashboard-aggregation.md`), so this type produces
/// exactly that shape instead of leaving each call site to get the boundary
/// right by hand — a one-day-off `end` would silently drop or double-count
/// the last day of a month.
public struct MonthPeriod: Sendable, Equatable {
    /// Inclusive start of the month.
    public let start: Date
    /// Exclusive end of the month — the first instant of the following month.
    public let end: Date

    private let calendar: Calendar

    private init(start: Date, end: Date, calendar: Calendar) {
        self.start = start
        self.end = end
        self.calendar = calendar
    }

    /// The month containing `now`.
    ///
    /// `calendar` and `now` are both injectable so tests don't depend on the
    /// wall clock or the device's calendar.
    public static func current(calendar: Calendar = .current, now: Date = Date()) -> MonthPeriod {
        month(containing: now, calendar: calendar)
    }

    /// The month immediately before this one.
    ///
    /// Steps one day back from `start` and re-derives the containing month,
    /// so this is correct across a year boundary (January's previous month
    /// is December of the prior year) without hand-rolled month arithmetic.
    public func previous() -> MonthPeriod {
        let anchor = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        return Self.month(containing: anchor, calendar: calendar)
    }

    /// The month immediately after this one.
    public func next() -> MonthPeriod {
        Self.month(containing: end, calendar: calendar)
    }

    /// A display title for the period picker, e.g. "August 2026" — localized
    /// to the calendar's locale rather than hardcoded to one language.
    public var title: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: start)
    }

    private static func month(containing date: Date, calendar: Calendar) -> MonthPeriod {
        guard let interval = calendar.dateInterval(of: .month, for: date) else {
            // `.month` is representable on every real Gregorian-family
            // calendar, so this should not happen in practice. Fall back to
            // a degenerate (empty) period anchored on `date` rather than
            // crashing.
            return MonthPeriod(start: date, end: date, calendar: calendar)
        }
        return MonthPeriod(start: interval.start, end: interval.end, calendar: calendar)
    }
}
