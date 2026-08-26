import Foundation

/// One bar of the dashboard's "Spesa giornaliera" chart, as produced by
/// `spendingBars(_:)`.
///
/// `fraction` is this bar's height relative to the tallest bar in the series,
/// in `0...1` — the view converts it to a concrete height at draw time,
/// keeping this type free of any drawing framework, same split as
/// `DonutSegment`.
public struct DailyBar: Sendable, Equatable {
    /// The bucket's start — a calendar day at the default `.day` granularity.
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

extension TraccioCore {
    /// Turn a currency's `by_bucket` breakdown into drawable bars.
    ///
    /// Unlike the pre-2026-08-26 `dailyBars(_:)`, this does **not** walk a
    /// calendar to invent zero bars between entries — the backend already
    /// gap-fills `by_bucket` across the whole requested period when both
    /// `start` and `end` were sent (`docs/decisions/
    /// 0007-dashboard-aggregation.md`'s third revision), so a client-side
    /// fill would either duplicate that work or silently disagree with it
    /// when the caller omitted a bound. `entries` is trusted to already be in
    /// chronological order, same trust `donutSegments(_:)` places in the
    /// backend's own sort.
    ///
    /// Parameters
    /// ----------
    /// entries:
    ///     One currency's `byBucket` list, in the order the backend returned
    ///     it.
    ///
    /// Returns
    /// -------
    /// One `DailyBar` per entry, in the same order. Empty if `entries` is
    /// empty.
    public static func spendingBars(_ entries: [BucketSummaryResponse]) -> [DailyBar] {
        guard !entries.isEmpty else { return [] }
        let maxSpending = entries.map(\.spending).max() ?? 0
        return entries.map { entry in
            let fraction = maxSpending > 0 ? Double(entry.spending) / Double(maxSpending) : 0
            return DailyBar(day: entry.start, spending: entry.spending, fraction: fraction)
        }
    }
}
