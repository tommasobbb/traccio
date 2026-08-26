import Foundation

/// A small, fixed set of period presets for filtering Movimenti — "this
/// month", "last month", and so on, resolved to the same half-open
/// `[start, end)` shape `TransactionFilter.start`/`.end` and
/// `GET /dashboard/summary` already use.
///
/// Deliberately minimal: only calendar-month-based presets plus "all time".
/// Longer or custom periods (quarter/year pickers, a scrubbable range) are
/// M3 backlog item 6 ("Panoramica redesign part 2") — this type is the seam
/// that extends, not a final design.
///
/// Display copy (e.g. "Questo mese") is not this type's job — the client is
/// officially Italian-only with hardcoded literals in the presentation layer
/// (`client/CLAUDE.md`), the same pattern `TransactionsView.title(for:)`
/// already follows for day-group headers, so a view maps a case to its label
/// itself.
public enum TransactionPeriodPreset: CaseIterable, Sendable, Equatable {
    case thisMonth
    case lastMonth
    case last3Months
    case thisYear
    case all

    /// The half-open `[start, end)` bound this preset represents.
    ///
    /// `calendar`/`now` are injectable so tests don't depend on the wall
    /// clock or the device's calendar, mirroring `MonthPeriod.current(calendar:now:)`.
    ///
    /// Parameters
    /// ----------
    /// calendar:
    ///     The calendar to resolve month/year boundaries against.
    /// now:
    ///     The instant "today" means.
    ///
    /// Returns
    /// -------
    /// (start: Date?, end: Date?)
    ///     Both `nil` for `.all` (no bound at all); otherwise both set.
    public func range(calendar: Calendar = .current, now: Date = Date()) -> (start: Date?, end: Date?) {
        switch self {
        case .all:
            return (nil, nil)
        case .thisMonth:
            let month = MonthPeriod.current(calendar: calendar, now: now)
            return (month.start, month.end)
        case .lastMonth:
            let month = MonthPeriod.current(calendar: calendar, now: now).previous()
            return (month.start, month.end)
        case .last3Months:
            let currentMonth = MonthPeriod.current(calendar: calendar, now: now)
            // Step back two more months from the current month's start, so
            // the window covers this month plus the two before it — three
            // calendar months total, ending at the current month's end.
            let start =
                calendar.date(byAdding: .month, value: -2, to: currentMonth.start) ?? currentMonth.start
            return (start, currentMonth.end)
        case .thisYear:
            guard let interval = calendar.dateInterval(of: .year, for: now) else {
                // `.year` is representable on every real Gregorian-family
                // calendar; fall back to no bound rather than crashing.
                return (nil, nil)
            }
            return (interval.start, interval.end)
        }
    }
}
