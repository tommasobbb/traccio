import Foundation

/// A calendar-aligned period — a month, quarter, or year — represented as a
/// half-open interval `[start, end)`.
///
/// Backs the dashboard's period selector. `GET /dashboard/summary` takes an
/// optional `start`/`end` pair where `end` is **exclusive**
/// (`docs/decisions/0007-dashboard-aggregation.md`), so this type produces
/// exactly that shape instead of leaving each call site to get the boundary
/// right by hand — a one-day-off `end` would silently drop or double-count
/// the last day of a period.
///
/// One type for all three units, not a separate `MonthPeriod`/`QuarterPeriod`/
/// `YearPeriod` in parallel — there is exactly one client and switching
/// `Unit` (Task 6's Mese/Trimestre/Anno segmented picker) is far cheaper
/// against a single type than three. Deliberately no arbitrary custom range
/// (a start/end date picker): that would double the picker surface for a
/// case nobody has asked for yet (YAGNI — add it if it turns out to matter).
public struct CalendarPeriod: Sendable, Equatable {
    /// The calendar unit this period spans.
    public enum Unit: Sendable, Equatable, CaseIterable {
        case month
        case quarter
        case year
    }

    /// Inclusive start of the period.
    public let start: Date
    /// Exclusive end of the period — the first instant of the unit that
    /// follows.
    public let end: Date
    public let unit: Unit

    private let calendar: Calendar

    private init(start: Date, end: Date, unit: Unit, calendar: Calendar) {
        self.start = start
        self.end = end
        self.unit = unit
        self.calendar = calendar
    }

    /// The period of `unit` containing `now`.
    ///
    /// `calendar` and `now` are both injectable so tests don't depend on the
    /// wall clock or the device's calendar.
    public static func current(
        unit: Unit = .month, calendar: Calendar = .current, now: Date = Date()
    ) -> CalendarPeriod {
        period(containing: now, unit: unit, calendar: calendar)
    }

    /// The period immediately before this one, same `unit`.
    ///
    /// Steps one day back from `start` and re-derives the containing period
    /// of the same unit, so this is correct across a year boundary (January's
    /// previous month is December of the prior year; Q1's previous quarter is
    /// Q4 of the prior year) without hand-rolled arithmetic per unit.
    public func previous() -> CalendarPeriod {
        let anchor = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        return Self.period(containing: anchor, unit: unit, calendar: calendar)
    }

    /// The period immediately after this one, same `unit`.
    public func next() -> CalendarPeriod {
        Self.period(containing: end, unit: unit, calendar: calendar)
    }

    /// Whether `date` falls inside this half-open interval (`start` inclusive,
    /// `end` exclusive).
    public func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }

    /// Whether this whole period lies strictly after `date` — its inclusive
    /// start is already past `date`, so nothing in it has happened yet. Used
    /// to stop the dashboard paging into a period that has not begun.
    public func isEntirelyAfter(_ date: Date) -> Bool {
        start > date
    }

    /// The `by_bucket` granularity `GET /dashboard/summary` should use for
    /// this period — coarse enough not to overwhelm the trend chart (a year
    /// at daily granularity would be 365 bars), fine enough to stay readable.
    public var granularity: BucketGranularity {
        switch unit {
        case .month: .day
        case .quarter: .week
        case .year: .month
        }
    }

    private static func period(containing date: Date, unit: Unit, calendar: Calendar) -> CalendarPeriod {
        switch unit {
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: date) else {
                return CalendarPeriod(start: date, end: date, unit: unit, calendar: calendar)
            }
            return CalendarPeriod(start: interval.start, end: interval.end, unit: unit, calendar: calendar)
        case .year:
            guard let interval = calendar.dateInterval(of: .year, for: date) else {
                return CalendarPeriod(start: date, end: date, unit: unit, calendar: calendar)
            }
            return CalendarPeriod(start: interval.start, end: interval.end, unit: unit, calendar: calendar)
        case .quarter:
            // Foundation's `dateInterval(of:for:)` does not portably support
            // `.quarter` — computed by hand from the containing year instead,
            // three calendar months at a time.
            guard let yearInterval = calendar.dateInterval(of: .year, for: date) else {
                return CalendarPeriod(start: date, end: date, unit: unit, calendar: calendar)
            }
            let month = calendar.component(.month, from: date)  // 1...12
            let quarterIndex = (month - 1) / 3  // 0...3
            guard
                let start = calendar.date(
                    byAdding: .month, value: quarterIndex * 3, to: yearInterval.start
                ),
                let end = calendar.date(byAdding: .month, value: 3, to: start)
            else {
                return CalendarPeriod(start: date, end: date, unit: unit, calendar: calendar)
            }
            return CalendarPeriod(start: start, end: end, unit: unit, calendar: calendar)
        }
    }
}
