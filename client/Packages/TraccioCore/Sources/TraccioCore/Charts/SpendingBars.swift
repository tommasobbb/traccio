import Foundation

/// One bar of the dashboard's "Spesa giornaliera" trend chart, as produced
/// by `spendingBars(_:)`.
///
/// `fraction` is this bar's height relative to the tallest bar in the
/// series, in `0...1` — the view converts it to a concrete height at draw
/// time, keeping this type free of any drawing framework, same split as
/// `DonutSegment`. Carries `start`/`end`/`transactionCount` (not just a
/// single day and an amount) because the scrubber's floating tooltip needs
/// the bucket's own interval and count, not only its spending — and, since
/// Task 6, a "bar" is not always a calendar day (quarter/year periods bucket
/// by week/month, `CalendarPeriod.granularity`).
public struct SpendingBar: Sendable, Equatable {
    /// The bucket's start, a local calendar date.
    public let start: CalendarDate
    /// The bucket's exclusive end.
    public let end: CalendarDate
    /// Total spending in this bucket, minor units, a non-negative magnitude.
    public let spending: Int
    /// How many transactions fall in this bucket.
    public let transactionCount: Int
    /// This bar's height relative to the series' tallest bar. `0` for every
    /// bar when the whole series is `0` (nothing to compare against).
    public let fraction: Double

    public init(
        start: CalendarDate, end: CalendarDate, spending: Int, transactionCount: Int, fraction: Double
    ) {
        self.start = start
        self.end = end
        self.spending = spending
        self.transactionCount = transactionCount
        self.fraction = fraction
    }
}

extension TraccioCore {
    /// Turn a currency's `by_bucket` breakdown into drawable bars.
    ///
    /// Does **not** walk a calendar to invent zero bars between entries —
    /// the backend already gap-fills `by_bucket` across the whole requested
    /// period when both `start` and `end` were sent (`docs/decisions/
    /// 0007-dashboard-aggregation.md`'s third revision), so a client-side
    /// fill would either duplicate that work or silently disagree with it
    /// when the caller omitted a bound. `entries` is trusted to already be
    /// in the backend's own order, same trust `donutSegments(_:)` places in
    /// its own input.
    ///
    /// Parameters
    /// ----------
    /// entries:
    ///     One currency's `byBucket` list, in the order the backend
    ///     returned it.
    ///
    /// Returns
    /// -------
    /// One `SpendingBar` per entry, in the same order. Empty if `entries` is
    /// empty.
    public static func spendingBars(_ entries: [BucketSummaryResponse]) -> [SpendingBar] {
        guard !entries.isEmpty else { return [] }
        let maxSpending = entries.map(\.spending).max() ?? 0
        return entries.map { entry in
            let fraction = maxSpending > 0 ? Double(entry.spending) / Double(maxSpending) : 0
            return SpendingBar(
                start: entry.start, end: entry.end, spending: entry.spending,
                transactionCount: entry.transactionCount, fraction: fraction
            )
        }
    }
}
